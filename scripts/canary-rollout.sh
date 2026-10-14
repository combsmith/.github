#!/usr/bin/env bash
set -euo pipefail
# canary-rollout.sh — ring-staged, health-gated promotion of agent releases by
# moving channel tags only (initiative #495, issue #501; rollback/observability #502).
#
# The ONLY action this performs is moving a channel tag (via `gh api` on the agent's host
# repo, with the release-manager App token — #1076) — it never writes consumer files. A ring advances
# only when the rings already on the candidate pass the soak/health gate (see
# scripts/lib/canary-rollout.sh for the pure decision core).
#
# Channel tags ARE the rollout state (#502): the frontier is derived from where each
# channel tag resolves; there is no separate state store.
#
# The FRONT END that closes the last manual seam (#1069): `autocut` polls each registered
# reusable and, when its blob on the host's main HEAD differs from the current `next`
# candidate, cuts a new immutable <agent>/vX.Y.Z and moves `next` onto it — seeding the soak/
# promote pipeline with no manual `cut-release.sh`. It is gated by CANARY_AUTO_CUT (the single
# kill-switch), runs BEFORE promote-all on the scheduled tick, and is best-effort.
#
# Usage:
#   canary-rollout.sh autocut      [--dry-run]         # cut+seed new candidates for changed reusables (gated by CANARY_AUTO_CUT)
#   canary-rollout.sh evaluate     <agent>             # read-only gate + health report (also the #502 report)
#   canary-rollout.sh evaluate-all                     # read-only evaluate for EVERY registry agent (fleet-wide; the 4h timer)
#   canary-rollout.sh promote  <agent> [--override] [--confirm] [--allow-pre-existing] [--dry-run]  # --confirm clears an AWAITING_CONFIRMATION hold (#668 Layer 3); NOT --override
#   canary-rollout.sh promote-all [--override] [--allow-pre-existing] [--dry-run]  # gated fleet auto-promote (the SCHEDULED arm, #1045b)
#   canary-rollout.sh rollback <agent> <ring> --to <vX.Y.Z> [--dry-run]
#   canary-rollout.sh resolve  <agent> <channel>       # debug: print resolved member repos
#   canary-rollout.sh sync-issues [--dry-run]          # blocker issue per BLOCKED agent + fleet-status table to the job summary (auto-triage)
#   canary-rollout.sh drift    [--emit-stub]           # read-only: report *-reusable.yml on a host but unregistered, + stale registry entries (#1082)
#
# Gate standard: .github#548 — graduated per-transition dwell/sample floors over a
# per-candidate cumulative window (since the candidate's OWN vX.Y.Z cut), a robust
# spike-capped baseline for the sample target, the ring0->ring1 sample waiver, and
# candidate-regression-vs-environmental failure triage. Knobs live in the ring SoT
# under .agents[<agent>].gate (see scripts/lib/canary-rollout.sh for the pure core).
#
# Env:
#   CANARY_RINGS        path to ring SoT (default: standards/canary-rings.json next to this repo)
#   SOAK_WINDOW_DAYS    optional override of the baseline-window length in days
#                       (default: .gate.baseline_window_days, else 14)
#   CANARY_FAILURE_CATEGORY  optional triage hint (comment-cap|rate-limit|infra|data)
#   CANARY_AUTO_CUT     autocut kill-switch — autocut is a no-op unless this == 'true'
#   GH_TOKEN            credential; the workflow mints a GitHub App token and passes it here

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/canary-rollout.sh
source "${_HERE}/lib/canary-rollout.sh"
DEFAULT_RINGS="$(cd "${_HERE}/.." && pwd)/standards/canary-rings.json"
CANARY_RINGS="${CANARY_RINGS:-$DEFAULT_RINGS}"

# The `autocut` front end (#1069) cuts new candidates INLINE via the App-token gh-api path
# (_gh_create_annotated_tag + _gh_move_tag against the agent's registry host) — it no longer
# shells out to a sibling cut-release.sh. That coupling broke when the engine relocated to
# .github (#613): cut-release.sh stayed in .github-private as the human/runbook CLI and does
# not travel with this checkout. Cutting inline keeps the engine self-contained and writes to
# the correct host for every agent (incl. dev-lead, hosted in .github-private).

# THIS_REPO — the repo this checkout belongs to. Agents hosted HERE (dev-lead, pr-review)
# keep their channel/release tags in this checkout and resolve them via local git. A
# cross-repo agent (host != THIS_REPO, e.g. the #482 reusables hosted in combsmith/
# .github) keeps its <name>/<channel> and <name>/vX.Y.Z tags on ITS host, so those tags
# must be resolved there via `gh api` — reading local refs resolves empty and the frontier
# falsely reports "fully rolled out" (#1049). Mirrors cut-release.sh's CROSS_REPO_TARGET.
THIS_REPO="${GITHUB_REPOSITORY:-combsmith/.github-private}"

_jq()  { jq "$@" "$CANARY_RINGS"; }
_agent_field() { _jq -r --arg a "$1" ".agents[\$a].$2"; }

# ordered_channels <agent> — e.g. "next,ring0,ring1,stable"
ordered_channels() {
  _jq -r --arg a "$1" '.agents[$a].rings | sort_by(.order) | map(.channel) | join(",")'
}

# resolve_members <agent> <channel> — print the member repos, expanding the
# host-relative tokens $host / $org_infra / * (one repo per line).
resolve_members() {
  local agent="$1" channel="$2" host t r
  host="$(_agent_field "$agent" host)"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      '$host') printf '%s\n' "$host" ;;
      '$org_infra')
        while IFS= read -r r; do
          if [ "$r" != "$host" ]; then printf '%s\n' "$r"; fi
        done < <(_jq -r '.org_infra_repos[]') ;;
      '*') printf '%s\n' '*' ;;
      *) printf '%s\n' "$t" ;;
    esac
  done < <(_jq -r --arg a "$agent" --arg c "$channel" \
            '.agents[$a].rings[] | select(.channel==$c) | .members[]')
  return 0
}

# _gh_tag_commit <repo> <tag> — echo the COMMIT sha <tag> resolves to on <repo> via the
# GitHub API, dereferencing an annotated tag object (mirrors cut-release.sh's
# gh_release_commit). Empty on any error / absent tag (never fails the caller).
_gh_tag_commit() {
  local repo="$1" tag="$2" ref_info obj type
  ref_info="$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[(.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)" || return 0
  [ -z "$ref_info" ] && return 0
  read -r obj type <<< "$ref_info"
  if [ "$type" = "tag" ]; then
    gh api "repos/$repo/git/tags/$obj" --jq '(.object?.sha // "" | tostring)' 2>/dev/null || true
  else
    printf '%s\n' "$obj"
  fi
}

# _gh_move_tag <repo> <tag> <sha> — force-move (or create) the lightweight ref
# refs/tags/<tag> on <repo> to <sha> via the GitHub API. THE channel-tag mover for every
# agent (promote + rollback), this-repo and cross-repo alike (#1076): the API path is
# granted the release-manager App's ruleset bypass for tag UPDATEs, whereas a local
# `git push --force` is not (013 on protected channel tags) and also fails with
# "nonexistent object" for a cross-repo host commit absent from this checkout (#1054).
# Tries PATCH (existing ref) then falls back to POST (create the ref).
_gh_move_tag() {
  [ $# -lt 3 ] && return 1
  local repo="$1" tag="$2" sha="$3"
  gh api -X PATCH "repos/$repo/git/refs/tags/$tag" \
      -f sha="$sha" -F force=true >/dev/null 2>&1 && return 0
  gh api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$sha" >/dev/null 2>&1
}

# _gh_create_annotated_tag <repo> <tag> <sha> <message> — create the immutable annotated
# tag object <tag> pointing at commit <sha> on <repo> and publish its ref, via the GitHub
# API with the release-manager App token (mirrors cut-release.sh's gh_create_annotated_tag).
# This is the CUT primitive for `autocut` (#1069): once the engine relocated to .github the
# sibling cut-release.sh no longer travels with it, so the cut runs inline through the same
# App-token path used for every other tag write — no dependency on a script left behind in
# another repo, and it writes to the agent's registry HOST (correct for the this-repo
# dev-lead agent whose reusable lives in .github-private, #613 relocation). Returns non-zero
# on API failure so the caller can degrade best-effort.
_gh_create_annotated_tag() {
  [ $# -lt 4 ] && return 1
  local repo="$1" tag="$2" sha="$3" message="$4" obj
  obj="$(gh api -X POST "repos/$repo/git/tags" \
      -f tag="$tag" -f message="$message" -f object="$sha" -f type=commit \
      --jq '.sha // empty')"
  if [ $? -ne 0 ] || [ -z "$obj" ]; then
      echo "::error::_gh_create_annotated_tag: could not create the annotated release tag on $repo or read back its object SHA" >&2
      return 1
  fi
  gh api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$obj" >/dev/null 2>&1 || {
      echo "::error::_gh_create_annotated_tag: created tag object $obj on $repo but could not publish ref refs/tags/$tag" >&2
      return 1
  }
}

# _agent_current_major <agent> — the MAJOR of the agent's highest vX.Y.Z release on its
# host, empty if none (major-scoped-channels epic #657, Phase F4). This is the "current
# major line" a v-scoped channel tag is derived against; there is no new registry field —
# it is derived from the release tags already present (mirrors _next_release_version).
declare -A _AGENT_MAJOR_CACHE=()

_agent_current_major() {
  local agent="$1"
  if [[ -v _AGENT_MAJOR_CACHE["$agent"] ]]; then
    echo "${_AGENT_MAJOR_CACHE["$agent"]}"
    return 0
  fi
  local versions highest major=""
  versions="$(_host_release_versions "$agent")"
  # shellcheck disable=SC2086
  highest="$(max_semver $versions)"
  if [ -n "$highest" ]; then
    major="$(major_component "$highest")"
  fi
  _AGENT_MAJOR_CACHE["$agent"]="$major"
  echo "$major"
}

# _channel_tag_commit <agent> <suffix> — commit the tag <agent>/<suffix> resolves to
# (empty if absent). Same host-vs-local resolution as channel_commit, generalized to an
# arbitrary channel suffix so a v-scoped `v<M>-<tier>` can be probed (epic #657 F4).
declare -A _CHANNEL_COMMIT_CACHE=()

_channel_tag_commit() {
  local agent="$1" suffix="$2" host key="${1}:${2}"
  if [[ -v _CHANNEL_COMMIT_CACHE["$key"] ]]; then
    echo "${_CHANNEL_COMMIT_CACHE["$key"]}"
    return 0
  fi
  local commit=""
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    commit="$(_gh_tag_commit "$host" "$agent/$suffix")"
  else
    commit="$(git rev-parse -q --verify "refs/tags/$agent/$suffix^{commit}" 2>/dev/null \
      || git rev-parse -q --verify "$agent/$suffix^{commit}" 2>/dev/null || true)"
  fi
  _CHANNEL_COMMIT_CACHE["$key"]="$commit"
  echo "$commit"
}

# _resolved_channel <agent> <tier> — echo "<tag>\t<commit>" for the channel <agent> uses on
# <tier>, fall-back-safe (major-scoped-channels epic #657, Phase F4): PREFER the v-scoped
# `<agent>/v<M>-<tier>` when it exists (its commit is a real oid), else the legacy bare
# `<agent>/<tier>`. On today's bare-tier fleet (no v-tags) this is byte-identical to pre-F4.
_resolved_channel() {
  local agent="$1" tier="$2" major tag suffix commit
  major="$(_agent_current_major "$agent")"
  if [ -n "$major" ]; then
    tag="$(channel_tag "$agent" "$tier" "$major")"; suffix="${tag#"$agent"/}"
    commit="$(_channel_tag_commit "$agent" "$suffix")"
    if _looks_like_oid "$commit"; then printf '%s\t%s\n' "$tag" "$commit"; return 0; fi
  fi
  tag="$(channel_tag "$agent" "$tier")"; suffix="${tag#"$agent"/}"
  printf '%s\t%s\n' "$tag" "$(_channel_tag_commit "$agent" "$suffix")"
}

# _resolved_channel_tag <agent> <tier> — just the resolved tag name (no commit).
_resolved_channel_tag() { _resolved_channel "$1" "$2" | cut -f1; }

# channel_commit <agent> <channel> — commit the channel <agent> uses on <channel> resolves
# to (empty if the tag does not exist). Resolution is fall-back-safe on the major dimension
# (epic #657 F4): prefer the v-scoped tag, else the bare tier. Agents hosted in THIS repo
# resolve against the local checkout; a cross-repo agent's channel tags live on ITS host, so
# they are resolved there via the GitHub API — reading local refs resolves empty and the
# frontier falsely reports "fully rolled out" (#1049).
channel_commit() {
  _resolved_channel "$1" "$2" | cut -f2
}

# _gate_field <agent> <field> — read .agents[a].gate.<field> (empty if absent).
_gate_field() { _jq -r --arg a "$1" --arg f "$2" '.agents[$a].gate[$f] // empty'; }
# _gate_knob <agent> <transition_key> <field> — read a per-transition knob (empty if absent).
_gate_knob() { _jq -r --arg a "$1" --arg t "$2" --arg f "$3" '.agents[$a].gate.transitions[$t][$f] // empty'; }

# _iso_now_minus_days <ndays> — ISO-8601 Zulu timestamp n days ago (GNU or BSD date).
_iso_now_minus_days() {
  date -u -d "-${1} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v"-${1}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}
_to_z() {   # normalise any parseable timestamp to ISO-8601 Zulu (empty passes through)
  [ -z "${1:-}" ] && { echo ""; return 0; }
  date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "$1"
}
_epoch() {
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -v "$1" +%s 2>/dev/null \
    || echo 0
}

# _gh_candidate_cut_date <repo> <agent> <commit> — ISO-8601 Zulu tagger date of the
# release tag <agent>/vX.Y.Z on <repo> whose (dereferenced) commit equals <commit>. The
# cross-repo analogue of the local for-each-ref path: a cross-repo agent's release tags
# live on its host, not this checkout (#1049). Empty if no matching release tag is found.
_gh_candidate_cut_date() {
  local repo="$1" agent="$2" commit="$3" obj type csha cdate
  while IFS=$'\t' read -r _ obj type; do
    [ -z "$obj" ] && continue
    if [ "$type" = "tag" ]; then
      IFS=$'\t' read -r csha cdate < <(gh api "repos/$repo/git/tags/$obj" \
        --jq '[(.object?.sha // "" | tostring), (.tagger?.date // "" | tostring)] | @tsv' 2>/dev/null) || true
    else
      csha="$obj"; cdate=""
    fi
    if [ "$csha" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(gh api "repos/$repo/git/matching-refs/tags/$agent/v" \
             --jq '.[]? | [.ref, (.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)
  echo ""
}

# candidate_cut_date <agent> <candidate_commit> — ISO-8601 Zulu tagger date of the
# immutable release tag <agent>/vX.Y.Z that points at the candidate commit. This is the
# per-candidate cumulative-window start (#548): health is measured since the candidate's
# OWN cut, NOT a rolling window — so a pre-cut failure of a prior version is excluded.
# For a cross-repo agent (host != THIS_REPO) the release tags live on the host, so the
# date is resolved there via the GitHub API instead of the local for-each-ref (#1049).
candidate_cut_date() {
  local agent="$1" commit="$2" host obj deref cdate c
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    _gh_candidate_cut_date "$host" "$agent" "$commit"
    return 0
  fi
  while IFS='|' read -r obj deref cdate; do
    c="$deref"; [ -z "$c" ] && c="$obj"
    if [ "$c" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(git for-each-ref \
             --format='%(objectname)|%(*objectname)|%(creatordate:iso-strict)' \
             "refs/tags/${agent}/v*" 2>/dev/null)
  git log -1 --format=%cI "$commit" 2>/dev/null || echo ""
}

# _run_json <repo> <workflow> <since_z> — gh run-list JSON (conclusion,createdAt,databaseId,workflowName) for a
# repo since the given Zulu timestamp. Empty repo/wildcard → []. Never fails the caller.
_run_json() {
  local repo="$1" wf="$2" since="$3" out
  [ -z "$repo" ] || [ "$repo" = '*' ] && { echo '[]'; return 0; }
  # Fail CLOSED on a genuine gh failure (network / rate-limit / expired creds): returning
  # an empty [] would read as "zero failures" and could green-light a bad promotion. A
  # non-zero return halts the run under `set -e` instead. An empty-but-successful result
  # (no runs) is still a valid [].
  if ! out="$(gh run list --repo "$repo" --workflow "$wf" ${since:+--created ">=$since"} \
      -L 1000 --json conclusion,createdAt,databaseId,workflowName 2>/dev/null)"; then
    echo "::error::_run_json: failed to fetch run list for $repo (workflow=$wf)" >&2
    return 1
  fi
  echo "${out:-[]}"
}

# _tier_sample <agent> <since_z> <repo...> — EXECUTED runs (success+failure) on the
# source tier since the candidate cut. Prints "<executed> <earliest_createdAt|->".
_tier_sample() {
  local agent="$1" since="$2"; shift 2
  local wf repo json executed=0 earliest="" e
  wf="$(_agent_field "$agent" run_workflow)"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    executed=$(( executed + $(jq '[.[]?|select(.conclusion=="success" or .conclusion=="failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    e="$(jq -r '[.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt?]|min // empty' 2>/dev/null <<< "$json" || echo "")"
    if [ -n "$e" ] && { [ -z "$earliest" ] || [[ "$e" < "$earliest" ]]; }; then earliest="$e"; fi
  done
  echo "$executed ${earliest:--}"
}

# _benign_patterns <agent> <differs 0|1> — emit the per-reusable known-benign
# failure-class allowlist (#1025 P2) as TSV "<workflow_regex>\t<step_regex>", one entry
# per line. Empty if none apply. differs-aware (#668): when the candidate CHANGED the
# reusable (differs=1) only classes explicitly marked `version_independent: true` are
# emitted — a failure that occurs before/independent of the candidate's own code (e.g. a
# Dependabot-context secrets failure at startup) can never be candidate-caused, so it may
# be excluded even for a changed reusable. Every OTHER class stays disabled at differs=1,
# preserving the invariant that the allowlist cannot mask a candidate-introduced regression.
_benign_patterns() {
  _jq -r --arg a "$1" --arg d "${2:-0}" \
    '.agents[$a]?.gate?.benign_failure_classes? // []
     | map(select($d == "0" or .version_independent == true))
     | .[] | [(.workflow // ""), (.step // "")] | @tsv'
}

# _suspect_patterns <agent> — emit the per-reusable SUSPECT failure-class allowlist
# (#668 increment 2) as TSV "<workflow_regex>\t<step_regex>", one entry per line. Empty if
# none. Unlike benign, suspect classes are emitted regardless of differs: a SUSPECT verdict
# only surfaces at differs=1 (see classify_failure), but the class always participates so a
# differs=1 counted failure is triaged SUSPECT (blocks + carries guidance) instead of a bare
# REGRESSION. Suspect classes are NEVER excluded from cum_fail — they still block.
_suspect_patterns() {
  _jq -r --arg a "$1" \
    '.agents[$a]?.gate?.suspect_failure_classes? // []
     | .[] | [(.workflow // ""), (.step // "")] | @tsv'
}

# _suspect_downgrade_patterns <agent> — emit the per-reusable SUSPECT classes that OPT INTO
# auto_downgrade (#668 increment 6) as TSV
# "<workflow_regex>\t<step_regex>\t<min_baseline_sample>\t<margin_permille>", one per line;
# empty when no suspect class carries `auto_downgrade` (byte-identical increment-2 behaviour:
# an un-flagged SUSPECT is never downgraded). The knobs travel WITH the pattern so the
# orchestrator feeds decide_suspect_downgrade per class without a second registry read.
_suspect_downgrade_patterns() {
  _jq -r --arg a "$1" \
    '.agents[$a]?.gate?.suspect_failure_classes? // []
     | .[] | select(.auto_downgrade? != null)
     | [(.workflow // ""), (.step // ""),
        (.auto_downgrade?.min_baseline_sample? // 0), (.auto_downgrade?.margin_permille? // 0)]
     | @tsv'
}

# _suspect_class_counts <agent> <since_z> <before_z|-> <wf_re> <step_re> <repo...> — over the
# window [since_z, before_z) on the given tier repos, echo "<matched_failures> <executed> <incomplete>":
# executed = success+failure runs; matched = the failures whose failed-step signature matches
# THIS one suspect class (via benign_match, the same matcher triage uses); incomplete = the
# count of failure runs whose signature could not be retrieved (gh run view error — callers
# treat incomplete>0 as HOLD, not DOWNGRADE, since an unreadable run could be a non-match).
# before_z="-" means no upper bound. Powers the candidate-vs-baseline SUSPECT-class failure
# RATE that the auto-downgrade core compares (#668 increment 6). Reuses _run_json /
# _run_signature (the signature cache is warm from the cumulative-health pass on the
# candidate window).
_suspect_class_counts() {
  local agent="$1" since="$2" before="$3" wf_re="$4" step_re="$5"; shift 5
  local wf repo json rid rwf sig sig_rc matched=0 executed=0 incomplete=0 count
  wf="$(_agent_field "$agent" run_workflow)"
  local exec_filter='.[]?|select(.conclusion=="success" or .conclusion=="failure")'
  local fail_filter='.[]?|select(.conclusion=="failure")'
  if [ "$before" != "-" ]; then
    exec_filter="$exec_filter|select(.createdAt < \"$before\")"
    fail_filter="$fail_filter|select(.createdAt < \"$before\")"
  fi
  for repo in "$@"; do
    { [ -z "$repo" ] || [ "$repo" = '*' ]; } && continue
    json="$(_run_json "$repo" "$wf" "$since")"
    count="$(jq "[${exec_filter}]|length" 2>/dev/null <<< "$json" || echo 0)"
    executed=$(( executed + ${count:-0} ))
    while IFS=$'\t' read -r rid rwf || [ -n "$rid" ]; do
      rid="${rid%$'\r'}"
      rwf="${rwf%$'\r'}"
      [ -z "$rid" ] && continue
      sig_rc=0
      sig="$(_run_signature "$repo" "$rid")" || sig_rc=$?  # || prevents set -e on lookup failure
      if [ -z "$sig" ]; then
        [ "$sig_rc" -ne 0 ] && incomplete=$(( incomplete + 1 ))  # lookup failed; genuine empty sig is fine
        continue
      fi
      if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then
        matched=$(( matched + 1 ))
      fi
    done < <(jq -r "[${fail_filter}]|.[]|[(.databaseId // \"\"|tostring),(.workflowName // \"\")]|@tsv" 2>/dev/null <<< "$json")
  done
  echo "$matched $executed $incomplete"
}

# Memoization cache for _run_signature: keyed by "repo:run_id".
# Avoids duplicate gh run view calls for the same (repo, run_id) across agents
# in evaluate-all (where multiple agents can share repos).
declare -A _RUN_SIG_CACHE=()

# _run_signature <repo> <run_id> — the failed step names of a run, joined by newlines
# (the "step/error signature" the allowlist matches against). Empty repo/wildcard/id or
# any gh error → "" with exit 1 (fail-closed: an unknown signature is never treated as
# benign, and callers that need to distinguish a lookup failure from a genuine empty
# signature check the exit code). A successful lookup with no failed steps → "" exit 0.
# The $'\x01' sentinel in the cache marks a prior lookup failure so it is not retried.
_run_signature() {
  local repo="$1" id="$2" cache_key sig json
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}"
  if [[ -v _RUN_SIG_CACHE["$cache_key"] ]]; then
    if [ "${_RUN_SIG_CACHE[$cache_key]}" = $'\x01' ]; then
      echo ""; return 1  # cached lookup failure — signal to caller
    fi
    echo "${_RUN_SIG_CACHE[$cache_key]}"
    return 0
  fi
  # Use || { } so set -e does not trigger on a failing gh run view; the block caches the
  # sentinel and returns 1 to signal the lookup failure to callers that care (e.g.
  # _suspect_class_counts tracks incomplete evidence and HOLDs the downgrade).
  json="$(gh run view "$id" --repo "$repo" --json jobs 2>/dev/null)" || {
    _RUN_SIG_CACHE["$cache_key"]=$'\x01'
    echo ""; return 1
  }
  sig="$(jq -r '[.jobs[]?|.steps[]?|select(.conclusion=="failure")|.name] | join("\n")' \
    2>/dev/null <<< "$json" || echo "")"
  _RUN_SIG_CACHE["$cache_key"]="$sig"
  echo "$sig"
}

# _failure_benign <repo> <run_id> <workflow_name> <patterns_tsv> — return 0 if this
# in-window failure matches any allowlist entry, else 1. Fail-closed on an empty signature.
_failure_benign() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re; do
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# _failure_suspect <repo> <run_id> <workflow_name> <patterns_tsv> — return 0 if this
# in-window failure matches any SUSPECT allowlist entry (#668 increment 2), else 1. Reuses
# the benign_match pure matcher against the run's failed-step signature; fail-closed on an
# empty signature (an unknown signature is never treated as suspect). A suspect match does
# NOT exclude the failure — it narrows the triage verdict (SUSPECT vs REGRESSION) only.
_failure_suspect() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re || [ -n "$wf_re" ]; do
    wf_re="${wf_re%$'\r'}"
    step_re="${step_re%$'\r'}"
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# _cumulative_health <agent> <since_z> <differs 0|1> <repo...> — failures +
# startup_failures across EVERY given tier repo since the candidate cut. Failures
# matching the per-reusable known-benign allowlist (#1025 P2) are counted separately and
# excluded from the blocking total; which allowlist entries apply depends on whether the
# candidate changed the reusable (differs — see _benign_patterns, #668). A counted (non-
# benign) failure that matches a `suspect_failure_classes` entry sets the suspect flag
# (#668 increment 2) — it still counts toward the blocking total (SUSPECT blocks like
# REGRESSION), but downstream triage renders SUSPECT + guidance instead of a bare
# REGRESSION. Prints "<failures> <startup_failures> <benign_excluded> <suspect_count>".
_cumulative_health() {
  local agent="$1" since="$2" differs="$3"; shift 3
  local wf repo json fail=0 startup=0 benign=0 suspect=0 patterns="" suspect_patterns="" rid rwf
  wf="$(_agent_field "$agent" run_workflow)"
  patterns="$(_benign_patterns "$agent" "$differs")"
  suspect_patterns="$(_suspect_patterns "$agent")"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    startup=$(( startup + $(jq '[.[]?|select(.conclusion=="startup_failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    if [ -z "$patterns" ] && [ -z "$suspect_patterns" ]; then
      # No benign or suspect patterns to match — count all failures with one jq pass,
      # avoiding a gh run view call per failure.
      fail=$(( fail + $(jq '[.[]?|select(.conclusion=="failure")]|length' 2>/dev/null <<< "$json" || echo 0) ))
    else
      while IFS=$'\t' read -r rid rwf; do
        if [ -n "$patterns" ] && _failure_benign "$repo" "$rid" "$rwf" "$patterns"; then
          benign=$(( benign + 1 ))
        else
          fail=$(( fail + 1 ))
          if [ -n "$suspect_patterns" ] && _failure_suspect "$repo" "$rid" "$rwf" "$suspect_patterns"; then
            suspect=$(( suspect + 1 ))
          fi
        fi
      done < <(jq -r '.[]?|select(.conclusion=="failure")|[(.databaseId // "" | tostring),(.workflowName // "")]|@tsv' 2>/dev/null <<< "$json")
    fi
  done
  echo "$fail $startup $benign $suspect"
}

# _baseline_daily <agent> <window_days> <repo...> — per-day EXECUTED counts on the
# source tier over the trailing window_days (exactly window_days integers, zero-filled),
# feeding the robust spike-capped baseline for the sample target (#548).
_baseline_daily() {
  local agent="$1" window="$2"; shift 2
  local wf since repo json dates="" day i count out=""
  wf="$(_agent_field "$agent" run_workflow)"
  since="$(_iso_now_minus_days "$window")"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    dates+="$(jq -r '.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt[0:10]?' 2>/dev/null <<< "$json" || true)"$'\n'
  done
  for (( i=0; i<window; i++ )); do
    day="$(date -u -d "-${i} days" +%Y-%m-%d 2>/dev/null || date -u -v"-${i}d" +%Y-%m-%d 2>/dev/null || echo "")"
    count=$(grep -c "^${day}$" 2>/dev/null <<< "$dates" || true)
    out+="${count} "
  done
  echo "${out% }"
}

# _reusable_differs <agent> <candidate_commit> <prior_commit> — 1 if the agent's reusable
# workflow blob differs between the candidate SHA and the prior channel SHA, else 0. Used
# by triage to confirm a CANDIDATE REGRESSION (#548): a failure whose reusable is identical
# to the prior version is pre-existing, not introduced by the candidate.
_reusable_differs() {
  local agent="$1" cand="$2" prior="$3" reusable a b host
  reusable="$(_agent_field "$agent" reusable)"
  [ -z "$reusable" ] || [ -z "$cand" ] || [ -z "$prior" ] && { echo 0; return 0; }
  host="$(_agent_field "$agent" host)"; host="${host:-$THIS_REPO}"
  if [ "$host" = "$THIS_REPO" ]; then
    # This-repo agent: the reusable blob lives in the local checkout.
    a="$(git rev-parse -q --verify "${cand}:${reusable}" 2>/dev/null || echo "")"
    b="$(git rev-parse -q --verify "${prior}:${reusable}" 2>/dev/null || echo "")"
  else
    # Cross-repo agent (#613): the reusable blob lives on the HOST repo, not locally —
    # a local `git rev-parse` would resolve empty and wrongly report "unchanged". Resolve
    # the blob SHA on the host via gh api, like the autocut path does.
    a="$(_gh_blob_sha "$host" "$reusable" "$cand")"
    b="$(_gh_blob_sha "$host" "$reusable" "$prior")"
  fi
  # Fail CLOSED: an unresolvable compare counts as "changed" so the benign-failure
  # allowlist is disabled and a genuine candidate regression is never masked.
  { [ -z "$a" ] || [ -z "$b" ]; } && { echo 1; return 0; }
  [ "$a" != "$b" ] && { echo 1; return 0; }
  echo 0
}

# ── decision telemetry sampling (#668 Layer 2, increment 4) ─────────────────────
# Feeds the pure decision-shift core (decide_decision_shift / decision_class in the lib)
# with real decision-mix tallies gathered from `gh run view --json jobs` step names — the
# same surface the benign/suspect check already fetches. Reserved for agents that opt into
# gate.correctness; every other agent skips this path entirely (byte-identical).

# Memoization for _run_decision_class, keyed "repo:run_id" (the decision class is
# prefix-independent given the run, so the prefix is not part of the key). Distinct from
# _RUN_SIG_CACHE: decision sampling hits SUCCESS runs, the signature cache hits FAILED runs,
# so the two never fetch the same run twice.
declare -A _RUN_DECISION_CACHE=()

# _run_decision_class <repo> <run_id> <prefix> — the decision class a run took (the taken
# `<prefix><class>` no-op step; skipped branches ignored), via `gh run view --json jobs`.
# Empty on missing repo/id or any gh error (fail-open: a run with no decision step simply
# contributes nothing to the tally, degrading toward INSUFFICIENT, never a false SHIFT).
_run_decision_class() {
  local repo="$1" id="$2" prefix="$3" cache_key json cls
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}"
  if [[ -v _RUN_DECISION_CACHE["$cache_key"] ]]; then
    echo "${_RUN_DECISION_CACHE[$cache_key]}"; return 0
  fi
  json="$(gh run view "$id" --repo "$repo" --json jobs 2>/dev/null || echo '{}')"
  cls="$(decision_class "$prefix" "$json")"
  _RUN_DECISION_CACHE["$cache_key"]="$cls"
  echo "$cls"
}

# _sample_decision_counts <agent> <prefix> <max_k> <since_z> <before_z|-> <repo...> — tally the
# decision-class mix of up to <max_k> EXECUTED runs (newest first) on the given tier repos in
# the window [since_z, before_z). before_z="-" means no upper bound (all runs since <since_z>).
# Runs with no decision step are skipped (they do not consume a sample slot). Echoes a compact
# JSON object "<class>":<count>; "{}" when nothing qualifies. Pure-core (decide_decision_shift)
# reads the object; the min-sample knobs gate sufficiency.
_sample_decision_counts() {
  local agent="$1" prefix="$2" max_k="$3" since="$4" before="$5"; shift 5
  local wf repo json rid cls sampled=0
  wf="$(_agent_field "$agent" run_workflow)"
  declare -A counts=()
  local filter='.[]?|select(.conclusion=="success" or .conclusion=="failure")'
  [ "$before" != "-" ] && filter="$filter|select(.createdAt < \"$before\")"
  for repo in "$@"; do
    [ "$sampled" -ge "$max_k" ] && break
    { [ -z "$repo" ] || [ "$repo" = '*' ]; } && continue
    json="$(_run_json "$repo" "$wf" "$since")"
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      [ "$sampled" -ge "$max_k" ] && break
      cls="$(_run_decision_class "$repo" "$rid" "$prefix")"
      [ -z "$cls" ] && continue
      counts["$cls"]=$(( ${counts["$cls"]:-0} + 1 ))
      sampled=$(( sampled + 1 ))
    done < <(jq -r "[${filter}]|sort_by(.createdAt)|reverse|.[]|(.databaseId|tostring)" 2>/dev/null <<< "$json")
  done
  # Build the counts object in a SINGLE jq pass (one process, not one per key) —
  # jq does the key/value escaping so arbitrary class names stay valid JSON.
  local out k
  out="$(for k in "${!counts[@]}"; do printf '%s\t%s\n' "$k" "${counts[$k]}"; done \
    | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null)"
  [ -n "$out" ] || out='{}'
  echo "$out"
}

# _correctness_verdict <agent> <cand_commit> <cut_z> <src_repos_csv> — OK|SHIFT|INSUFFICIENT for
# an agent that opts into gate.correctness (empty when it does not). Candidate mix = source-tier
# runs since the candidate cut; baseline mix = source-tier runs in the trailing window BEFORE the
# cut (the prior version on identical traffic — the enumerable stand-in for "the incumbent on
# comparable traffic", since the stable ring is often the unenumerable `*`). Delegates the gate
# to the pure decide_decision_shift.
_correctness_verdict() {
  local agent="$1" cand="$2" cut_z="$3" src_csv="$4"
  local knobs prefix
  knobs="$(_jq -c --arg a "$agent" '.agents[$a].gate.correctness')"
  prefix="$(jq -r '.decision_step_prefix // "decision: "' <<< "$knobs" 2>/dev/null || echo "decision: ")"
  local src_repos=() r
  IFS=, read -r -a src_repos <<< "$src_csv"
  local win base_since cand_counts base_counts
  win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
  base_since="$(_iso_now_minus_days "$win")"
  # K=15 candidate / K=25 baseline — n in the 10–25 band the design targets; the min-sample
  # knobs (below the caps) gate sufficiency, so a thin sample degrades to INSUFFICIENT.
  cand_counts="$(_sample_decision_counts "$agent" "$prefix" 15 "$cut_z" "-" "${src_repos[@]}")"
  base_counts="$(_sample_decision_counts "$agent" "$prefix" 25 "$base_since" "$cut_z" "${src_repos[@]}")"
  decide_decision_shift "$cand_counts" "$base_counts" "$knobs"
}

# _decision_mix_table <agent> <cand_commit> — a markdown table of the candidate vs prior-version
# baseline decision-class share (permille, rounded like decide_decision_shift), for the blocker
# body of a correctness-SHIFT hold (#668 L2). Recomputes the same source-tier samples as
# _correctness_verdict (the per-run classes are memoized in _RUN_DECISION_CACHE, so the second
# pass is cache-warm). Empty when the agent has no gate.correctness or the frontier is resolved.
_decision_mix_table() {
  local agent="$1" cand="$2"
  local knobs; knobs="$(_jq -c --arg a "$agent" '.agents[$a].gate.correctness // ""')"
  [ -z "$knobs" ] || [ "$knobs" = '""' ] && return 0
  local chans frontier="" ch c
  chans="$(ordered_channels "$agent")"
  local chan_array=(); IFS=, read -r -a chan_array <<< "$chans"
  for ch in "${chan_array[@]}"; do
    c="$(channel_commit "$agent" "$ch")"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
  done
  [ -z "$frontier" ] && return 0
  local transition source cut_z prefix
  transition="$(transition_key "$frontier" "$chans")"
  source="${transition%%->*}"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  [ -z "$cut_z" ] && return 0
  prefix="$(jq -r '.decision_step_prefix // "decision: "' <<< "$knobs" 2>/dev/null || echo "decision: ")"
  local src_repos=() r
  while IFS= read -r r; do [ -n "$r" ] && src_repos+=("$r"); done < <(resolve_members "$agent" "$source")
  local win base_since cand_counts base_counts
  win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
  base_since="$(_iso_now_minus_days "$win")"
  cand_counts="$(_sample_decision_counts "$agent" "$prefix" 15 "$cut_z" "-" "${src_repos[@]}")"
  base_counts="$(_sample_decision_counts "$agent" "$prefix" 25 "$base_since" "$cut_z" "${src_repos[@]}")"
  # Guard against an empty sample string — --argjson rejects empty input.
  # (A `${var:-{}}` inline default is NOT usable: the inner `}` closes the
  #  parameter expansion, appending a stray brace and producing invalid JSON.)
  [ -n "$cand_counts" ] || cand_counts='{}'
  [ -n "$base_counts" ] || base_counts='{}'
  jq -nr --argjson c "$cand_counts" --argjson b "$base_counts" --arg win "$win" '
    ([$c[]?]|add // 0) as $ct | ([$b[]?]|add // 0) as $bt
    | (($c|keys) + ($b|keys) | unique) as $classes
    | "| decision class | candidate | baseline | Δ |",
      "|---|---|---|---|",
      ( $classes[]
        | ( if $ct>0 then ((( ($c[.]//0)*1000 + ($ct/2) ) / $ct) | floor) else 0 end ) as $cs
        | ( if $bt>0 then ((( ($b[.]//0)*1000 + ($bt/2) ) / $bt) | floor) else 0 end ) as $bs
        | (($cs - $bs) | if . < 0 then -. else . end) as $d
        | "| `\(.)` | \($cs/10)% (\($c[.]//0)) | \($bs/10)% (\($b[.]//0)) | \($d/10)pp |" ),
      "",
      "_candidate n=\($ct) (source tier since cut) · baseline n=\($bt) (prior version, trailing \($win) d). Share = rounded per-mille; Δ is the absolute shift the gate compares to `max_shift_permille`._"
  ' 2>/dev/null || return 0
}

# _frontier_state <agent> — compute the rollout frontier and graduated gate, echoing:
#   "<cand> <frontier> <transition> <state> <dwell_h> <dwell_floor> <sample> <target> <cum_fail> <cum_startup> <cum_benign> <triage> <mix_shift> <downgrade> <dg_cand_rate> <dg_cand_sample> <dg_base_rate> <dg_base_sample>"
# frontier = first ring (after next) not yet on the candidate commit; triage is "-"
# unless state is BLOCKED (then REGRESSION | PRE_EXISTING | SUSPECT). mix_shift is "SHIFT"
# when a gate.correctness decision-mix shift is holding the promotion (#668 L2), else "-".
# downgrade is "DOWNGRADE" when a SUSPECT was auto-downgraded to PRE_EXISTING (#668 inc6) —
# then triage already reads PRE_EXISTING and dg_* carry the candidate-vs-baseline permille
# rates + sample sizes that drove it; "-"/0 otherwise.
_frontier_state() {
  local agent="$1"
  local cand chans frontier=""
  cand="$(channel_commit "$agent" next)"
  chans="$(ordered_channels "$agent")"

  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  local ch
  for ch in "${chan_array[@]}"; do
    local c; c="$(channel_commit "$agent" "$ch")"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
  done
  if [ -z "$frontier" ]; then
    echo "$cand - - COMPLETE 0 0 0 0 0 0 0 - -"; return 0
  fi

  local transition source cut_z now_epoch
  transition="$(transition_key "$frontier" "$chans")"
  source="${transition%%->*}"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  if [ -z "$cut_z" ]; then
    # Cannot determine the per-candidate window start — fail closed to prevent unbounded history queries.
    echo "$cand $frontier $transition BLOCKED 0 0 0 0 0 0 0 - -"; return 0
  fi
  now_epoch="$(date -u +%s)"

  # Source-tier repos (the tier currently running the candidate).
  local src_repos=() r
  while IFS= read -r r; do [ -n "$r" ] && src_repos+=("$r"); done < <(resolve_members "$agent" "$source")

  # Sample on the source tier over the per-candidate window.
  local sample earliest
  read -r sample earliest < <(_tier_sample "$agent" "$cut_z" "${src_repos[@]}")

  # Dwell is always measured from the candidate's own cut (tagger date), per #548 spec.
  local dwell_h=0
  local cut_epoch; cut_epoch="$(_epoch "$cut_z")"
  if [ "$cut_epoch" -gt 0 ]; then
    dwell_h=$(( (now_epoch - cut_epoch) / 3600 ))
  fi
  [ "$dwell_h" -lt 0 ] && dwell_h=0

  # Whether the candidate changed the agent's reusable vs the prior channel on the frontier.
  # At differs=1 the known-benign allowlist narrows to classes marked version_independent
  # (#668) — inherently context-caused failures that can never be candidate-introduced —
  # and every other class is disabled, so the allowlist can never mask a candidate-introduced
  # regression (#1025 P2).
  local prior differs
  prior="$(channel_commit "$agent" "$frontier")"
  differs="$(_reusable_differs "$agent" "$cand" "$prior")"

  # Cumulative health across EVERY concrete tier repo since the candidate's own cut.
  local all_repos=() ch3
  for ch3 in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all_repos+=("$r"); done \
      < <(resolve_members "$agent" "$ch3")
  done
  local cum_fail cum_startup cum_benign cum_suspect
  read -r cum_fail cum_startup cum_benign cum_suspect < <(_cumulative_health "$agent" "$cut_z" "$differs" "${all_repos[@]}")

  # Per-transition knobs (registry-configurable; #548 defaults live in the ring SoT).
  local dwell_floor waived="false" target=0
  dwell_floor="$(_gate_knob "$agent" "$transition" dwell_hours)"; dwell_floor="${dwell_floor:-0}"
  if [ "$(_gate_knob "$agent" "$transition" waive_sample)" = "true" ]; then
    waived="true"
  elif [ -n "$(_gate_knob "$agent" "$transition" sample_min)" ]; then
    target="$(_gate_knob "$agent" "$transition" sample_min)"
  else
    local win frac cmin cmax spike_cap daily baseline_total
    win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
    frac="$(_gate_knob "$agent" "$transition" sample_fraction_permille)"; frac="${frac:-250}"
    cmin="$(_gate_knob "$agent" "$transition" sample_clamp_min)"; cmin="${cmin:-3}"
    cmax="$(_gate_knob "$agent" "$transition" sample_clamp_max)"; cmax="${cmax:-15}"
    spike_cap="$(_gate_field "$agent" baseline_spike_cap_multiple)"; spike_cap="${spike_cap:-3}"
    daily="$(_baseline_daily "$agent" "$win" "${src_repos[@]}")"
    baseline_total=0; for c in $daily; do baseline_total=$(( baseline_total + c )); done
    if [ "$baseline_total" -eq 0 ] && [ "$(_gate_knob "$agent" "$transition" waive_sample_if_no_caller)" = "true" ]; then
      waived="true"   # dwell-only: the source tier has no caller (#548)
    else
      # shellcheck disable=SC2086
      target="$(robust_sample_target "$frac" "$cmin" "$cmax" "$spike_cap" $daily)"
    fi
  fi

  local state; state="$(decide_graduated "$dwell_h" "$dwell_floor" "$sample" "$target" "$waived" "$cum_fail" "$cum_startup")"

  # Layer 2 (#668 increment 4): opt-in DECISION telemetry. When the reliability verdict is
  # PROMOTE and the agent opts into gate.correctness, tally the candidate's decision mix vs a
  # prior-version baseline; a gross distribution SHIFT HOLDS the promotion (BLOCKED, triage
  # SUSPECT — the correctness variant, flagged by mix_shift). INSUFFICIENT/OK are no-ops, so an
  # agent that produces no comparable signal degrades to reliability-only. The overlay fires
  # ONLY from an otherwise-PROMOTE verdict — it never masks or bypasses a reliability BLOCK, and
  # it never rolls back or auto-acts (worst case: a few hours of human latency).
  local mix_shift="-"
  if [ "$state" = "PROMOTE" ] && [ -n "$(_gate_field "$agent" correctness)" ]; then
    local src_csv verdict
    src_csv="$(IFS=,; echo "${src_repos[*]}")"
    verdict="$(_correctness_verdict "$agent" "$cand" "$cut_z" "$src_csv")"
    if [ "$verdict" = "SHIFT" ]; then
      state="BLOCKED"; mix_shift="SHIFT"
    fi
  fi

  # Layer 3 (#668 increment 3): opt-in human confirmation at a ring boundary. When the
  # reliability verdict is PROMOTE but the frontier transition sets require_confirmation, hold
  # in a distinct AWAITING_CONFIRMATION state — SOAKING-like: the scheduled promote-all never
  # auto-advances it. It is cleared only by a deliberate `promote <agent> --confirm` (the
  # dispatch IS the confirmation; no state store). The overlay fires ONLY from an otherwise-
  # PROMOTE (reliability-clean) verdict, so `--confirm` can never bypass a BLOCKED gate.
  if [ "$state" = "PROMOTE" ] && [ "$(_gate_knob "$agent" "$transition" require_confirmation)" = "true" ]; then
    state="AWAITING_CONFIRMATION"
  fi

  # Triage: a correctness SHIFT is SUSPECT (correctness variant, distinguished by mix_shift);
  # any other BLOCK is classified from the failure evidence.
  local triage="-"
  if [ "$state" = "BLOCKED" ] && [ "$mix_shift" = "SHIFT" ]; then
    triage="SUSPECT"
  elif [ "$state" = "BLOCKED" ]; then
    triage="$(classify_failure "$differs" "${CANARY_FAILURE_CATEGORY:-unknown}" "$cum_suspect")"
  fi

  # SUSPECT → PRE_EXISTING auto-downgrade (#668 increment 6, opt-in per suspect class). Only the
  # failure-class SUSPECT variant is eligible — mix_shift="-" excludes the correctness variant,
  # which is never rate-comparable. For each suspect class carrying `auto_downgrade`, compare the
  # candidate's failure RATE for that class (matched/executed over the per-candidate window) with
  # the prior version's over the trailing baseline window; the pure decide_suspect_downgrade
  # decides. DOWNGRADE re-triages PRE_EXISTING (report-only: no needs-human, advances with
  # --allow-pre-existing); HOLD stays SUSPECT (increment-2 behaviour — worse/ambiguous/thin cases
  # keep the human). Byte-identical for a suspect class with no auto_downgrade (empty set → skip).
  local downgrade="-" dg_cand_rate=0 dg_cand_sample=0 dg_base_rate=0 dg_base_sample=0
  if [ "$triage" = "SUSPECT" ] && [ "$mix_shift" = "-" ]; then
    local dg_patterns; dg_patterns="$(_suspect_downgrade_patterns "$agent")"
    # Guard (Thread 1): only attempt per-class rate comparison when EVERY blocking failure
    # has been attributed to a suspect class. If any failure had no matching suspect class,
    # that unrelated failure is an independent regression and must keep the gate blocked.
    if [ -n "$dg_patterns" ] && [ "${cum_suspect:-0}" -ge "$cum_fail" ]; then
      local dg_win dg_base_since dwf dsr dmin dmargin cm ce cmi bm be bei crate brate knobs decision
      dg_win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; dg_win="${dg_win:-14}"
      dg_base_since="$(_iso_now_minus_days "$dg_win")"
      while IFS=$'\t' read -r dwf dsr dmin dmargin || [ -n "$dwf" ]; do
        dwf="${dwf%$'\r'}"; dsr="${dsr%$'\r'}"; dmin="${dmin%$'\r'}"; dmargin="${dmargin%$'\r'}"
        [ -z "$dsr" ] && continue
        read -r cm ce cmi < <(_suspect_class_counts "$agent" "$cut_z" "-" "$dwf" "$dsr" "${src_repos[@]}")
        read -r bm be bei < <(_suspect_class_counts "$agent" "$dg_base_since" "$cut_z" "$dwf" "$dsr" "${src_repos[@]}")
        # Guard (Thread 2): if any signature lookup failed, baseline class evidence is
        # incomplete. A missing run could be a non-match; fail-closed and skip DOWNGRADE.
        [ "${cmi:-0}" -gt 0 ] || [ "${bei:-0}" -gt 0 ] && continue
        if [ "${ce:-0}" -gt 0 ]; then crate="$(round_div $(( ${cm:-0} * 1000 )) "$ce")"; else crate=0; fi
        if [ "${be:-0}" -gt 0 ]; then brate="$(round_div $(( ${bm:-0} * 1000 )) "$be")"; else brate=0; fi
        knobs="$(printf '{"min_baseline_sample":%s,"margin_permille":%s}' "${dmin:-0}" "${dmargin:-0}")"
        decision="$(decide_suspect_downgrade "$crate" "$brate" "$be" "$knobs")"
        if [ "$decision" = "DOWNGRADE" ]; then
          triage="PRE_EXISTING"; downgrade="DOWNGRADE"
          dg_cand_rate="$crate"; dg_cand_sample="$ce"; dg_base_rate="$brate"; dg_base_sample="$be"
          break
        fi
      done <<< "$dg_patterns"
    fi
  fi

  echo "$cand $frontier $transition $state $dwell_h $dwell_floor $sample $target $cum_fail $cum_startup $cum_benign $triage $mix_shift $downgrade $dg_cand_rate $dg_cand_sample $dg_base_rate $dg_base_sample"
}

cmd_evaluate() {
  local agent="$1"
  echo "== canary-rollout evaluate: $agent (gate standard: .github#548) =="
  local cand_tag cand
  IFS=$'\t' read -r cand_tag cand < <(_resolved_channel "$agent" next)
  echo "candidate (${cand_tag#"$agent"/}) = ${cand:0:12}  cut=$(candidate_cut_date "$agent" "$cand")"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  local ch
  for ch in "${chan_array[@]}"; do
    local ch_tag c
    IFS=$'\t' read -r ch_tag c < <(_resolved_channel "$agent" "$ch")
    local mark="  "; [ -n "$cand" ] && [ "$c" = "$cand" ] && mark="* "
    printf '  %s%-7s -> %s\n' "$mark" "${ch_tag#"$agent"/}" "${c:0:12}"
  done
  read -r _cand frontier transition state dwell floor sample target cum_fail cum_startup cum_benign triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample < <(_frontier_state "$agent")
  echo "----"
  if [ "$frontier" = "-" ]; then
    echo "frontier: none — fully rolled out (all rings on candidate)."
  else
    gate_summary_line "$transition" "$state" "$dwell" "$floor" "$sample" "$target" "$cum_fail" "$cum_startup" "$cum_benign"
    echo "decision for next ring '$frontier' [$transition]: $state"
    if [ "$state" = "BLOCKED" ]; then
      if [ "$triage" = "REGRESSION" ]; then
        echo "::error::triage=REGRESSION — candidate changed the reusable and a run failed since cut. HALT + hold; recommend rollback."
      elif [ "$triage" = "SUSPECT" ] && [ "$mix_shift" = "SHIFT" ]; then
        echo "::warning::triage=SUSPECT (decision-mix shift, #668 Layer 2) — the candidate's decision distribution moved ≥ threshold vs the prior-version baseline. HOLDS the promotion; review the decision-mix table in the blocker issue. Composition drift (e.g. a draft-PR burst) is the usual false positive → promote --override to dismiss; a genuine always/never shift → roll back."
      elif [ "$triage" = "SUSPECT" ]; then
        echo "::warning::triage=SUSPECT — failure matches a suspect class (possibly candidate-caused). BLOCKS + needs a human; see the blocker issue's discriminating question, then promote --override if unrelated or roll back if a real regression."
      elif [ "$downgrade" = "DOWNGRADE" ]; then
        echo "::notice::triage=PRE_EXISTING (auto-downgraded from SUSPECT, #668 increment 6) — the candidate's suspect-class failure rate (${dg_cand_rate}‰ over ${dg_cand_sample} runs) is no worse than the prior version's (${dg_base_rate}‰ over ${dg_base_sample} runs), so the timeout is environmental, not a candidate regression. Report only; the SUSPECT hold auto-cleared (no human needed). Advances with --allow-pre-existing once dwell/sample pass."
      else
        echo "::warning::triage=PRE_EXISTING — failure is pre-existing/environmental. Report only; do NOT rollback, do NOT advance."
      fi
    elif [ "$state" = "AWAITING_CONFIRMATION" ]; then
      echo "::notice::state=AWAITING_CONFIRMATION — reliability PASSED; holding for an opt-in human go/no-go at $transition (#668 Layer 3). Review the canary-confirm issue, then dispatch: promote $agent --confirm  (not --override)."
    fi
  fi
}

# cmd_evaluate_all — read-only evaluate for EVERY agent in the ring registry (#1025 P1).
# The 4h schedule runs this so the whole fleet is evaluated on the timer, not just one
# agent. Iterates the registry keys, so newly-registered reusables are picked up with no
# workflow change. Never mutates (evaluate is read-only).
cmd_evaluate_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents | keys[]' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to evaluate."; return 0
  fi
  echo "== canary-rollout evaluate-all: fleet-wide (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_evaluate "$agent" || rc=$?
  done <<< "$agents"
  return "$rc"
}

cmd_promote() {
  local agent="$1"; shift
  local override=false dry=false allow_pre_flag=false confirm=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --override) override=true ;;
      --confirm)  confirm=true ;;
      --dry-run)  dry=true ;;
      --allow-pre-existing) allow_pre_flag=true ;;
      *) echo "::error::unknown promote flag: $1" >&2; return 2 ;;
    esac; shift
  done
  read -r cand frontier transition state _dwell _floor _sample _target cum_fail _cum_startup _cum_benign triage _mix_shift _dg _dgcr _dgcs _dgbr _dgbs < <(_frontier_state "$agent")
  if [ "$frontier" = "-" ]; then
    echo "nothing to promote — $agent is fully rolled out."; return 0
  fi
  # allow_pre: advance a BLOCKED frontier ONLY when triage=PRE_EXISTING (never REGRESSION).
  # Sourced from the per-reusable control block or the --allow-pre-existing flag (#1025 P2).
  local allow_pre
  allow_pre="$(_jq -r --arg a "$agent" '.agents[$a].gate?.control?.allow_pre_existing // false')"
  [ "$allow_pre_flag" = true ] && allow_pre=true
  # REGRESSION and SUSPECT both HALT + need a human: neither advances without --override,
  # and --allow-pre-existing (which only unblocks PRE_EXISTING) never advances them. For a
  # SUSPECT the human answers the class's discriminating question first — `--override` when
  # the timeout is unrelated to the diff, or roll back when the candidate got materially
  # slower (#668 increment 2).
  if [ "$state" = "BLOCKED" ] && { [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; } && [ "$override" != true ]; then
    echo "::error::gate=BLOCKED (triage=$triage) for '$frontier' [$transition] — candidate regression suspected; not promoting. Investigate + rollback, do not --override blindly."
    return 0
  fi
  local advance=false
  [ "$state" = "PROMOTE" ] && advance=true
  [ "$override" = true ] && advance=true
  [ "$state" = "BLOCKED" ] && [ "$triage" = "PRE_EXISTING" ] && [ "$allow_pre" = true ] && advance=true
  # Layer 3 (#668 increment 3): a human --confirm advances an AWAITING_CONFIRMATION frontier
  # (reliability is already PROMOTE — the state is only ever set from an otherwise-PROMOTE
  # verdict). --confirm is NOT --override: it clears ONLY this state and can never advance a
  # BLOCKED gate, so it cannot bypass reliability.
  [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$confirm" = true ] && advance=true
  if [ "$advance" != true ]; then
    if [ "$state" = "AWAITING_CONFIRMATION" ]; then
      echo "gate=AWAITING_CONFIRMATION for ring '$frontier' [$transition] — reliability PASSED; holding for an opt-in human go/no-go. Review the canary-confirm issue, then dispatch: promote $agent --confirm  (--confirm advances ONLY this reliability-clean state; it is NOT --override)."
    else
      echo "gate=$state for ring '$frontier' [$transition] (cum_fail=$cum_fail, triage=$triage) — not promoting. (use --override, or --allow-pre-existing for a PRE_EXISTING triage, after investigating)"
    fi
    return 0
  fi
  if [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$confirm" = true ]; then
    echo "::notice::human confirmation received (--confirm) — advancing $agent/$frontier [$transition] past the confirmation go/no-go (reliability was already PROMOTE)."
  elif [ "$state" != "PROMOTE" ]; then
    echo "::warning::advancing $agent/$frontier despite gate state '$state' (triage=$triage)"
  fi
  # Consistent move (#1076): EVERY agent moves its channel tag via `gh api` on its HOST
  # repo — never a local `git push`. A local force-push is NOT granted the release-manager
  # App's ruleset bypass for a tag UPDATE, so it 013s on a protected channel tag such as
  # dev-lead/next; the API path (same App token) IS honored as a bypass actor. host
  # defaults to THIS_REPO for an agent whose registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  # Move the RESOLVED frontier tag (major-scoped-channels epic #657, F4): advance the
  # v-scoped `<agent>/v<M>-<tier>` within its major line when it exists, else the legacy
  # bare `<agent>/<tier>`. A v2 promotion never touches a v1 tag. The logical tier
  # ($frontier) is unchanged — it still drives the gate + is reported as promoted_ring.
  local frontier_tag; frontier_tag="$(_resolved_channel_tag "$agent" "$frontier")"
  echo "advancing $frontier_tag -> ${cand:0:12} on $host"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$frontier_tag sha=$cand (force)"
    return 0
  fi
  _gh_move_tag "$host" "$frontier_tag" "$cand" \
    || { echo "::error::failed to move $frontier_tag -> ${cand:0:12} on $host" >&2; return 1; }
  echo "promoted $frontier_tag -> ${cand:0:12}"
  # Expose the move for the workflow's GitHub Deployment (traceability, #502). The
  # deployment must be created on the repo that OWNS the moved commit: a cross-repo agent's
  # candidate SHA lives on its host, NOT on THIS_REPO — creating the deployment against
  # GITHUB_REPOSITORY 422s with "No ref found" (#1059). So emit the owning repo too.
  local deploy_repo="$host"   # the repo that OWNS the moved commit (#1059); host==THIS_REPO for this-repo agents
  # GITHUB_OUTPUT is single-valued (last write wins), fine for a single `promote`. For
  # `promote-all` (many promotions per run) the workflow reads CANARY_PROMOTIONS_LOG — one
  # TSV line per promotion — so it can record a deployment for EVERY move, not just the last.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "promoted_agent=$agent"; echo "promoted_ring=$frontier"
      echo "promoted_sha=$cand";   echo "promoted_host=$deploy_repo"; } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${CANARY_PROMOTIONS_LOG:-}" ]; then
    printf '%s\t%s\t%s\t%s\n' "$agent" "$frontier" "$cand" "$deploy_repo" >> "$CANARY_PROMOTIONS_LOG"
  fi
}

# cmd_promote_all [--override] [--allow-pre-existing] [--dry-run] — the gated fleet
# auto-promote and the SCHEDULED arm of the automation (#1045 part b). Iterates every
# registry agent and calls cmd_promote for each, so each PROMOTE-ready agent advances
# exactly one ring per run while BLOCKED/REGRESSION agents are left untouched by the gate
# unless --override is passed (the scheduled workflow never passes it). A per-agent
# failure is logged and skipped so one agent cannot halt the fleet sweep. Flags are
# forwarded verbatim to every cmd_promote.
cmd_promote_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to promote."; return 0
  fi
  echo "== canary-rollout promote-all: fleet-wide (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_promote "$agent" "$@" || { rc=$?; echo "::warning::promote of $agent returned $rc (continuing fleet)"; }
  done <<< "$agents"
  return "$rc"
}

cmd_rollback() {
  local agent="$1" ring="$2"; shift 2
  local to="" dry=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)
        if [ $# -lt 2 ]; then echo "::error::--to requires a value" >&2; return 2; fi
        to="$2"; shift
        ;;
      --dry-run) dry=true ;;
      *) echo "::error::unknown rollback flag: $1" >&2; return 2 ;;
    esac; shift
  done
  [ -z "$to" ] && { echo "::error::rollback requires --to <vX.Y.Z>" >&2; return 2; }
  # Consistent path (#1076), mirroring cmd_promote: the target lookup AND the move both go
  # through gh api on the agent's HOST repo for every agent — never local git. host defaults
  # to THIS_REPO for an agent whose registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  local target
  target="$(_gh_tag_commit "$host" "$agent/$to")"
  [ -z "$target" ] && { echo "::error::release tag $agent/$to not found on $host" >&2; return 1; }
  echo "rolling back $agent/$ring -> $to (${target:0:12}) on $host"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$agent/$ring sha=$target (force)"
    return 0
  fi
  _gh_move_tag "$host" "$agent/$ring" "$target" \
    || { echo "::error::failed to move $agent/$ring -> $to on $host" >&2; return 1; }
  echo "rolled back $agent/$ring -> $to"
}

# ── blocker-issue + fleet-status automation (auto-triage of held promotions) ────
# The gate detects + classifies a BLOCKED promotion; sync-issues turns that signal into
# a tracked work item: one idempotent issue per BLOCKED agent (with the failing-run
# evidence pre-attached), auto-closed when the gate clears, plus the whole-fleet status
# table rendered into the run's job summary (a read-only snapshot — not an issue). Runs on
# the schedule after promote-all. All GitHub writes are best-effort — a failure here never
# fails the promotion run.
ISSUE_REPO="${ISSUE_REPO:-$THIS_REPO}"

# _issue_find <label> <marker> — "<number>\t<STATE>" of the newest issue carrying <marker>
# in its body (matched locally over the label's issues, not GitHub search — HTML-comment
# markers are not reliably indexed). Empty if none.
_issue_find() {
  local label="$1" marker="$2"
  gh issue list --repo "$ISSUE_REPO" --label "$label" --state all -L 100 \
      --json number,state,body 2>/dev/null \
    | jq -r --arg m "$marker" \
        '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | last
         | if . == null then "" else "\(.number)\t\(.state | ascii_upcase)" end' 2>/dev/null \
    || echo ""
}

# _gh_issue_create <title> <body> <labels_csv> — create an issue, echo its number.
_gh_issue_create() {
  gh issue create --repo "$ISSUE_REPO" --title "$1" --body "$2" --label "$3" 2>/dev/null \
    | grep -oE '[0-9]+$' | tail -1
}

# _blocker_evidence <agent> <candidate_commit> — markdown bullets for the in-window failing
# runs (repo + run link + failed-step signature), capped at 8. Uses the SAME per-candidate
# window + tier repos the gate counts, so the evidence matches cum_fail.
_blocker_evidence() {
  local agent="$1" cand="$2" wf cut_z repo json r n=0 out=""
  wf="$(_agent_field "$agent" run_workflow)"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  [ -z "$cut_z" ] && { printf '_(no candidate cut date resolved — cannot list failing runs)_\n'; return 0; }
  local chan_array=() ch all=() seen=" " dedup=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  for ch in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all+=("$r"); done < <(resolve_members "$agent" "$ch")
  done
  for r in "${all[@]}"; do case "$seen" in *" $r "*) ;; *) dedup+=("$r"); seen+="$r ";; esac; done
  for repo in "${dedup[@]}"; do
    json="$(_run_json "$repo" "$wf" "$cut_z")"
    local rid sig
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      if [ "$n" -ge 8 ]; then out+="- _(…more failing runs; truncated at 8)_"$'\n'; printf '%s' "$out"; return 0; fi
      sig="$(_run_signature "$repo" "$rid" | tr '\n' ';' | sed 's/;$//')"
      out+="- \`$repo\` — run [$rid](https://github.com/$repo/actions/runs/$rid); failed steps: ${sig:-unknown}"$'\n'
      n=$((n+1))
    done < <(jq -r '.[]?|select(.conclusion=="failure" or .conclusion=="startup_failure")|(.databaseId|tostring)' 2>/dev/null <<< "$json")
  done
  [ -z "$out" ] && out="_(no failing runs in the per-candidate window — cum_fail may be startup_failures or a transient count)_"$'\n'
  printf '%s' "$out"
}

# _suspect_guidance <agent> — emit the discriminating question(s) for the agent's
# suspect_failure_classes (#668 increment 2), one bullet per class, so a SUSPECT blocker
# tells the human exactly how to confirm in ~30 seconds. Empty if the agent has none.
_suspect_guidance() {
  _jq -r --arg a "$1" \
    '.agents[$a]?.gate?.suspect_failure_classes? // []
     | .[] | select((.guidance // "") != "")
     | "- **\(.id):** \(.guidance)"'
}

# _blocker_body <agent> <transition> <cand> <cum_fail> <cum_startup> <triage> <host> <evidence> [<mix_shift>] [<mix_table>] [<downgrade>] [<dg_cand_rate>] [<dg_cand_sample>] [<dg_base_rate>] [<dg_base_sample>]
_blocker_body() {
  local agent="$1" transition="$2" cand="$3" cum_fail="$4" cum_startup="$5" triage="$6" host="$7" evidence="$8" mix_shift="${9:--}" mix_table="${10:-}" note
  local downgrade="${11:--}" dg_cand_rate="${12:-0}" dg_cand_sample="${13:-0}" dg_base_rate="${14:-0}" dg_base_sample="${15:-0}"
  # Correctness variant (#668 L2): a decision-mix SHIFT holds as SUSPECT but is NOT a reliability
  # failure — the candidate exited green yet its decision distribution moved. Distinct note + a
  # candidate-vs-baseline mix table replace the failing-runs evidence (there are none).
  if [ "$triage" = "SUSPECT" ] && [ "$mix_shift" = "SHIFT" ]; then
    note="> ⚠️ **SUSPECT (decision-mix shift, #668 Layer 2)** — reliability PASSED (the candidate exits green), but its decision-class distribution shifted materially vs the prior version on comparable traffic. This HOLDS and needs a human (labelled \`needs-human\`): decide whether the shift is an intended behaviour change (\`promote --override\`) or a correctness regression (roll back). The gate never rolls back on its own."
    cat <<EOF
<!-- canary-blocker:$agent -->
**Automated canary-rollout blocker.** The release gate is holding \`$agent\` and will not promote it until this clears. Filed + maintained by the Canary Rollout workflow (gate standard: .github#548); this issue is **regenerated each run and auto-closes** when the gate passes — do not edit the table below by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| triage | **SUSPECT** (decision-mix shift) |

$note

### Decision-mix (candidate vs prior-version baseline)
${mix_table:-_(mix table unavailable — samples could not be resolved)_}
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
    return 0
  fi
  if [ "$triage" = "REGRESSION" ]; then
    note="> ⛔ **REGRESSION** — the candidate changed the reusable and a run failed since its cut. HALT + hold; investigate and roll back rather than \`--override\`. (labelled \`needs-human\`)"
  elif [ "$triage" = "SUSPECT" ]; then
    local guidance; guidance="$(_suspect_guidance "$agent")"
    [ -z "$guidance" ] && guidance="- _(no per-class guidance registered)_"
    note="> ⚠️ **SUSPECT** — the candidate changed the reusable and a run failed with a *possibly-candidate-caused* signature. This still BLOCKS and needs a human (labelled \`needs-human\`), but answer the discriminating question below to confirm fast: if unrelated to the diff, \`promote --override\`; if the candidate is materially responsible, treat it as a real regression and roll back.
>
> **Discriminating question:**
$(printf '%s\n' "$guidance" | sed 's/^/> /')"
  elif [ "$downgrade" = "DOWNGRADE" ]; then
    note="> ℹ️ **PRE_EXISTING** — *auto-downgraded from SUSPECT (#668 increment 6).* This failure matched a suspect class that opts into data-driven auto-downgrade, and the candidate's failure rate for that class is **no worse** than the prior version's on comparable traffic — so it is environmental, not a candidate regression. The SUSPECT hold auto-cleared: report only, **no human needed**, and the frontier advances with \`--allow-pre-existing\` once dwell/sample pass. (A materially-worse or thin-baseline case would have stayed SUSPECT.)
>
> **Suspect-class failure rate (candidate vs prior-version baseline):**
>
> | version | rate (‰) | runs |
> |---|---|---|
> | candidate | \`$dg_cand_rate\` | $dg_cand_sample |
> | baseline | \`$dg_base_rate\` | $dg_base_sample |"
  else
    note="> ⚠️ **PRE_EXISTING** — the failure is pre-existing/environmental (reusable byte-identical to the prior channel). Report only; the gate will not roll back or advance. Fix-forward, and the armed timer auto-promotes once clean."
  fi
  cat <<EOF
<!-- canary-blocker:$agent -->
**Automated canary-rollout blocker.** The release gate is holding \`$agent\` and will not promote it until this clears. Filed + maintained by the Canary Rollout workflow (gate standard: .github#548); this issue is **regenerated each run and auto-closes** when the gate passes — do not edit the table below by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| cumulative failures | **$cum_fail** (startup_failures: $cum_startup) |
| triage | **$triage** |

$note

### Failing runs in the per-candidate window
$evidence
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
}

# _confirm_body <agent> <transition> <cand> <prior> <host> <sample> <target> — the body of the
# evidence-carrying human-confirmation issue for an AWAITING_CONFIRMATION frontier (#668 Layer 3).
# Reliability has PASSED; a human confirms the candidate is behaving CORRECTLY (not merely exiting
# green) before it reaches the stable tier (all consumers). Marker-keyed (canary-confirm:<agent>)
# so sync-issues upserts it idempotently and auto-closes it on promote/candidate change.
_confirm_body() {
  local agent="$1" transition="$2" cand="$3" prior="$4" host="$5" sample="$6" target="$7"
  local suspect; suspect="$(_suspect_guidance "$agent")"
  local watch=""
  [ -n "$suspect" ] && watch="

### Watch for (suspect classes registered for this agent)
$suspect"
  local diff_link
  if [ -n "$prior" ]; then
    diff_link="https://github.com/$host/compare/${prior}...${cand}"
  else
    diff_link="(no prior stable release)"
  fi
  local display_prior="${prior:0:12}"
  display_prior="${display_prior:-none}"
  cat <<EOF
<!-- canary-confirm:$agent -->
**Canary rollout — human confirmation requested (\`$transition\`).**

The release gate holds \`$agent\` in **AWAITING_CONFIRMATION**: reliability has PASSED (dwell + sample + cumulative health all clean), but this transition is flagged \`require_confirmation\` (#668 Layer 3), so a human confirms the candidate is behaving *correctly* — not merely exiting green — before it reaches the stable tier (all consumers). Filed + maintained by the Canary Rollout workflow; **regenerated each run and auto-closes** when the promotion is confirmed or the candidate changes — do not edit by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| current stable | \`$display_prior\` |
| host repo | \`$host\` |
| reliability | ✅ PROMOTE — source-tier sample **$sample** (target ≥ $target), cumulative health clean |

### Review the candidate
- **Diff (current stable → candidate):** $diff_link
- Skim the changed reusable logic and the recent green runs on the ring1 tier before confirming.$watch

### Confirm or hold
- **Go:** dispatch the **Canary Rollout** workflow → command \`promote\`, agent \`$agent\`, **confirm = true** (or run \`promote $agent --confirm\` locally). \`--confirm\` advances ONLY this reliability-clean state; it is **not** \`--override\` and cannot bypass a failing gate.
- **No-go:** if the candidate looks wrong, roll back instead of confirming (\`rollback $agent <ring> --to <prior release>\`).
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
}

# _dashboard_md <rows_md> <timestamp> — the fleet-status table. This is a read-only snapshot
# (not a work item), so it is rendered into the GitHub Actions run's job summary — NOT filed
# as an issue: it needs no Issues:write, spawns no synthetic pinned issue, and shows on the
# run's Summary page every tick. The per-agent BLOCKED issues remain issues (they are
# trackable, assignable, closable work items).
_dashboard_md() {
  cat <<EOF
# Canary Rollout — fleet status

Last updated: \`$2\` · auto-promote armed: \`${CANARY_AUTO_PROMOTE:-unset}\` · gate standard: .github#548.

| agent | state | transition | cum_fail | triage | blocker |
|---|---|---|---|---|---|
$1

\`PROMOTE\`/\`COMPLETE\`/\`SOAKING\` need no action. \`BLOCKED\` opens a per-agent issue (label \`canary-blocker\`) with the failing-run evidence; it auto-closes when the gate clears. \`AWAITING_CONFIRMATION\` (reliability passed, held for a human go/no-go at a \`require_confirmation\` boundary, #668 Layer 3) opens a \`canary-confirm\` issue with the diff link; confirm via \`promote <agent> --confirm\`.
EOF
}

# cmd_sync_issues [--dry-run] — upsert one blocker issue per BLOCKED agent, and render the
# fleet-status table into the run's job summary (GITHUB_STEP_SUMMARY). Blocker issues are
# idempotent (marker-keyed) and auto-close when the gate clears. Best-effort: never fails the
# run. Reads ISSUE_REPO (default THIS_REPO).
cmd_sync_issues() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  local agents; agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  [ -z "$agents" ] && { echo "no agents registered in $CANARY_RINGS — nothing to sync."; return 0; }
  echo "== canary-rollout sync-issues: repo=$ISSUE_REPO dry=$dry (gate standard: .github#548) =="
  if [ "$dry" != true ]; then
    gh label create canary-blocker --repo "$ISSUE_REPO" --color ededed --description "canary-rollout automation" >/dev/null 2>&1 || true
    # Route blockers so they get ACTIONED, not left sitting: `dev-lead` (dev-lead-intent
    # treats a `dev-lead`-labelled issue as an actionable "issue" intent and picks it up —
    # the App token applies the label, so the `issues: labeled` event DOES trigger the agent,
    # unlike a github.token edit). `needs-human` additionally flags REGRESSION and SUSPECT
    # blockers, which the gate escalates to a human (roll back, or confirm the discriminating
    # question then --override, rather than a blind --override).
    gh label create dev-lead --repo "$ISSUE_REPO" --color 5319e7 --description "Route to the dev-lead agent for action" >/dev/null 2>&1 || true
    gh label create needs-human --repo "$ISSUE_REPO" --color d93f0b --description "Requires human judgement (canary regression)" >/dev/null 2>&1 || true
    # canary-confirm (#668 Layer 3): the human go/no-go issue for an AWAITING_CONFIRMATION
    # frontier — a SEPARATE label/issue from canary-blocker so the two concerns never collide.
    gh label create canary-confirm --repo "$ISSUE_REPO" --color fbca04 --description "canary-rollout: human go/no-go at a require_confirmation ring boundary" >/dev/null 2>&1 || true
  fi
  local rows="" agent
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    local cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift host
    local downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample
    read -r cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample < <(_frontier_state "$agent")
    host="$(_agent_field "$agent" host)"
    local blk="—" num_state num istate
    # Best-effort (#1081): these substitutions call gh/jq. Under `set -euo pipefail`
    # a bare assignment propagates a non-zero exit and would abort the whole step —
    # before the fleet dashboard renders and before the intended fallback warnings
    # below. `|| true` keeps sync-issues degrading gracefully (empty → handled).
    num_state="$(_issue_find canary-blocker "<!-- canary-blocker:$agent -->" || true)"
    num="${num_state%%$'\t'*}"; istate="${num_state##*$'\t'}"
    if [ "$state" = "BLOCKED" ]; then
      local evidence body title mix_table=""
      evidence="$(_blocker_evidence "$agent" "$cand" || true)"
      [ "$mix_shift" = "SHIFT" ] && mix_table="$(_decision_mix_table "$agent" "$cand" || true)"
      body="$(_blocker_body "$agent" "$transition" "$cand" "$cum_fail" "$cum_startup" "$triage" "$host" "$evidence" "$mix_shift" "$mix_table" "$downgrade" "$dg_cand_rate" "$dg_cand_sample" "$dg_base_rate" "$dg_base_sample")"
      if [ "$mix_shift" = "SHIFT" ]; then
        title="Canary blocker: $agent $transition (decision-mix shift, SUSPECT)"
      else
        title="Canary blocker: $agent $transition (cum_fail=$cum_fail, $triage)"
      fi
      if [ -z "$num" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN blocker issue for $agent ($triage)"; blk="(new)"; else
          num="$(_gh_issue_create "$title" "$body" "canary-blocker" || true)"
          if [ -n "$num" ]; then
            gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead >/dev/null 2>&1 || true
            { [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; } && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened blocker issue #$num for $agent"; blk="#$num"
          else echo "::warning::could not open blocker issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE blocker issue #$num for $agent"; blk="#$num"; else
          [ "$istate" = "OPEN" ] || gh issue reopen "$num" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$num" --repo "$ISSUE_REPO" --title "$title" --body "$body" >/dev/null 2>&1 \
            || echo "::warning::could not update blocker issue #$num for $agent"
          gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead >/dev/null 2>&1 || true
          if [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; then
            gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          else
            gh issue edit "$num" --repo "$ISSUE_REPO" --remove-label needs-human >/dev/null 2>&1 || true
          fi
          echo "  updated blocker issue #$num for $agent"; blk="#$num"
        fi
      fi
    else
      # Not blocked — close a stale open blocker issue (the gate cleared).
      if [ -n "$num" ] && [ "$istate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared blocker issue #$num for $agent ($state)"; else
          gh issue close "$num" --repo "$ISSUE_REPO" \
            --comment "✅ Gate cleared — \`$agent\` is now \`$state\`. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed cleared blocker issue #$num for $agent"
        fi
        blk="#$num (closed)"
      fi
    fi

    # Layer 3 (#668 increment 3): the human go/no-go issue for an AWAITING_CONFIRMATION frontier.
    # A SEPARATE marker/label from the blocker issue (the two concerns are independent), upserted
    # idempotently and auto-closed once the agent is no longer awaiting confirmation (promoted,
    # rolled back, or a new candidate cut). Labelled needs-human — a human confirms, dev-lead does
    # not action it. Best-effort under set -e, like the blocker path (`|| true`).
    local cnum_state cnum cistate
    cnum_state="$(_issue_find canary-confirm "<!-- canary-confirm:$agent -->" || true)"
    cnum="${cnum_state%%$'\t'*}"; cistate="${cnum_state##*$'\t'}"
    if [ "$state" = "AWAITING_CONFIRMATION" ]; then
      local prior cbody ctitle
      prior="$(channel_commit "$agent" "$frontier" || true)"
      cbody="$(_confirm_body "$agent" "$transition" "$cand" "$prior" "$host" "$_s" "$_t" || true)"
      ctitle="Canary confirm: $agent $transition — human go/no-go before stable"
      if [ -z "$cnum" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN confirm issue for $agent"; blk="(new confirm)"; else
          cnum="$(_gh_issue_create "$ctitle" "$cbody" "canary-confirm" || true)"
          if [ -n "$cnum" ]; then
            gh issue edit "$cnum" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened confirm issue #$cnum for $agent"; blk="#$cnum (confirm)"
          else echo "::warning::could not open confirm issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE confirm issue #$cnum for $agent"; blk="#$cnum (confirm)"; else
          [ "$cistate" = "OPEN" ] || gh issue reopen "$cnum" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$cnum" --repo "$ISSUE_REPO" --title "$ctitle" --body "$cbody" >/dev/null 2>&1 \
            || echo "::warning::could not update confirm issue #$cnum for $agent"
          gh issue edit "$cnum" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          echo "  updated confirm issue #$cnum for $agent"; blk="#$cnum (confirm)"
        fi
      fi
    else
      # No longer awaiting — close a stale open confirm issue (confirmed, rolled back, or recut).
      if [ -n "$cnum" ] && [ "$cistate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared confirm issue #$cnum for $agent ($state)"; else
          gh issue close "$cnum" --repo "$ISSUE_REPO" \
            --comment "✅ No longer awaiting confirmation — \`$agent\` is now \`$state\`. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed cleared confirm issue #$cnum for $agent"
        fi
        blk="#$cnum (confirm closed)"
      fi
    fi

    rows+="| \`$agent\` | $state | \`$transition\` | $cum_fail | $triage | $blk |"$'\n'
  done <<< "$agents"

  # Render the fleet-status table into the run's job summary (a read-only snapshot, not a
  # work item). Falls back to stdout when GITHUB_STEP_SUMMARY is unset (local/manual runs).
  local ts dmd
  ts="$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo unknown)"
  dmd="$(_dashboard_md "${rows%$'\n'}" "$ts")"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '\n%s\n' "$dmd" >> "$GITHUB_STEP_SUMMARY"; then
      echo "  wrote fleet-status table to the job summary"
    else
      echo "::warning::could not write the fleet-status job summary"
    fi
  else
    echo "──── fleet status ────"
    printf '%s\n' "$dmd"
  fi
  return 0
}

# ── autocut: cut a new candidate when a reusable changes on main (#1069) ────────
# The FRONT END of the canary pipeline (the promoter's counterpart). At each scheduled
# tick — gated by CANARY_AUTO_CUT — for each registered agent it compares the reusable
# blob at the host's default-branch HEAD against the blob at the current `next` candidate;
# if they differ it cuts a new immutable <agent>/vX.Y.Z (patch bump by default) and moves
# `next` onto it INLINE via the App-token gh-api path (_gh_create_annotated_tag + _gh_move_tag),
# seeding the candidate into the existing soak/promote pipeline. Detection AND the cut both run
# against the agent's registry host via the App token (which reads/writes every host), so no
# cross-repo Actions plumbing — and no sibling cut-release.sh — is needed. Best-effort: never
# fails the run.
#
# Scope/limitation (v1): detection is on the reusable FILE blob only (the registry
# `reusable` path). A change to a shared library the reusable sources — without the
# reusable file itself changing — is not detected. Acceptable for v1; could extend to a
# path-set later.

# _gh_default_branch <repo> — the repo's default branch name (empty on error).
_gh_default_branch() { gh api "repos/$1" --jq '.default_branch' 2>/dev/null || echo ""; }

# _gh_head_sha <repo> <branch> — the commit SHA at <branch> HEAD (empty on error).
_gh_head_sha() { gh api "repos/$1/commits/$2" --jq '.sha' 2>/dev/null || echo ""; }

# _gh_blob_sha <repo> <path> <ref> — the git blob SHA of <path> at <ref> (empty on error).
_gh_blob_sha() { gh api "repos/$1/contents/$2?ref=$3" --jq '.sha' 2>/dev/null || echo ""; }

# _host_release_versions <agent> — echo every MAJOR.MINOR.PATCH (one per line) that has an
# immutable <agent>/vX.Y.Z tag on the agent's host, via the API (the App token reads every
# host; release tags are on the remote for both this-repo and cross-repo agents).
_host_release_versions() {
  local agent="$1" host
  host="$(_agent_field "$agent" host)"
  [ -z "$host" ] && return 0
  gh api "repos/$host/git/matching-refs/tags/$agent/v" --jq '.[]?.ref' 2>/dev/null \
    | sed -n "s#^refs/tags/${agent}/v##p" || true
}

# _autocut_bump <agent> — the configured bump level for the agent (registry knob
# .agents[a].autocut.bump), defaulting to patch. Anything but minor/major → patch.
_autocut_bump() {
  local b
  b="$(_jq -r --arg a "$1" '.agents[$a]?.autocut?.bump // "patch"')"
  case "$b" in major|minor|patch) echo "$b" ;; *) echo "patch" ;; esac
}

# _next_release_version <agent> <bump> — compute the next release version: bump the highest
# existing <agent>/vX.Y.Z on the host by <bump>. No existing tags → seed from 0.0.0.
_next_release_version() {
  local agent="$1" bump="$2" versions highest
  versions="$(_host_release_versions "$agent")"
  # shellcheck disable=SC2086
  highest="$(max_semver $versions)"
  [ -z "$highest" ] && highest="0.0.0"
  bump_version "$highest" "$bump"
}

# _autocut_agent <agent> <dry:true|false> — cut a new candidate for ONE agent if its reusable
# blob on the host default-branch HEAD differs from the blob at the current `next` candidate.
# Idempotent: no-op when the blobs match or main HEAD already equals the next candidate.
# Best-effort: any resolution gap is a ::warning + skip, never a hard failure.
_autocut_agent() {
  local agent="$1" dry="$2"
  local host reusable defbranch mainsha next_commit main_blob next_blob bump newver
  host="$(_agent_field "$agent" host)"
  reusable="$(_agent_field "$agent" reusable)"
  if [ -z "$host" ] || [ -z "$reusable" ]; then
    echo "::warning::autocut $agent: missing host/reusable in registry — skipping"; return 0
  fi
  defbranch="$(_gh_default_branch "$host")"; [ -z "$defbranch" ] && defbranch="main"
  mainsha="$(_gh_head_sha "$host" "$defbranch")"
  if [ -z "$mainsha" ]; then
    echo "::warning::autocut $agent: could not resolve $host $defbranch HEAD — skipping"; return 0
  fi
  main_blob="$(_gh_blob_sha "$host" "$reusable" "$mainsha")"
  if [ -z "$main_blob" ]; then
    echo "::warning::autocut $agent: reusable '$reusable' not found at $host@${mainsha:0:12} — skipping"; return 0
  fi
  local next_resolved_tag
  IFS=$'\t' read -r next_resolved_tag next_commit < <(_resolved_channel "$agent" next)
  next_blob=""
  [ -n "$next_commit" ] && next_blob="$(_gh_blob_sha "$host" "$reusable" "$next_commit")"
  # Idempotency: nothing to cut when main HEAD already IS the candidate, or the reusable blob
  # is byte-identical between main and the current next candidate.
  if [ "$mainsha" = "$next_commit" ] || { [ -n "$next_blob" ] && [ "$main_blob" = "$next_blob" ]; }; then
    echo "autocut $agent: reusable unchanged on $host (next candidate up to date) — no cut."
    return 0
  fi
  bump="$(_autocut_bump "$agent")"
  newver="$(_next_release_version "$agent" "$bump")"
  # Seed/advance the correct `next` line on the major dimension (major-scoped-channels epic
  # #657, F4): a MAJOR bump opens a FRESH `<agent>/v<newmajor>-next` line (a brand-new major
  # never reuses the prior major's next), whereas a minor/patch bump advances the CURRENT
  # major's `v<M>-next` — falling back to the legacy bare `<agent>/next` on today's bare-tier
  # fleet where no v-line exists yet, so the move stays byte-identical until F5 migrates tags.
  local next_tag newmajor; newmajor="$(major_component "$newver")"
  if [ "$bump" = major ]; then
    next_tag="$(channel_tag "$agent" next "$newmajor")"
  else
    next_tag="$next_resolved_tag"
  fi
  echo "autocut $agent: reusable changed on $host ($defbranch ${mainsha:0:12}) vs next ${next_commit:0:12} — cutting v$newver (bump=$bump), moving $next_tag."
  local relver="$agent/v$newver"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: cut $relver at ${mainsha:0:12} on $host + move $next_tag (gh-api, App token)"
    return 0
  fi
  # Cut inline (no sibling cut-release.sh, #613): create the immutable annotated release tag,
  # then advance `next` onto the same commit — both on the agent's HOST via the App token. If
  # the release tag already exists (e.g. a retry after a partial move), skip the create and just
  # re-point next so the operation stays idempotent. Guard the invariant: if the existing tag
  # resolves to a different commit (manual retag, concurrent run, prior bad state), skip the
  # next move entirely rather than advancing next to an untagged commit.
  local existing_sha
  existing_sha="$(_gh_tag_commit "$host" "$relver")"
  if [ -n "$existing_sha" ]; then
    if [ "$existing_sha" != "$mainsha" ]; then
      echo "::warning::autocut $agent: release $relver on $host points to ${existing_sha:0:12}, not ${mainsha:0:12} — skipping next move to preserve invariant."
      return 0
    fi
    echo "autocut $agent: release $relver already exists on $host — re-pointing next only."
  elif ! _gh_create_annotated_tag "$host" "$relver" "$mainsha" "$agent release v$newver"; then
    echo "::warning::autocut $agent: could not create $relver on $host (best-effort, continuing)"; return 0
  fi
  _gh_move_tag "$host" "$next_tag" "$mainsha" \
    || { echo "::warning::autocut $agent: could not move $next_tag on $host (best-effort, continuing)"; return 0; }
  echo "autocut $agent: cut v$newver from ${mainsha:0:12} and moved $next_tag (on $host)."
}

# cmd_autocut [--dry-run] — the scheduled front end. Gated by CANARY_AUTO_CUT (the single
# kill-switch): a clean no-op unless CANARY_AUTO_CUT == 'true'. Iterates every registry agent;
# a per-agent failure is logged and skipped so one agent cannot halt the fleet sweep. Runs
# BEFORE promote-all so a freshly cut candidate begins soaking the same tick (dwell=0 < floor
# → it SOAKS, does not promote).
cmd_autocut() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  if [ "${CANARY_AUTO_CUT:-}" != "true" ]; then
    echo "== canary-rollout autocut: DISABLED (CANARY_AUTO_CUT != 'true') — no-op. =="
    return 0
  fi
  local agents agent
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  [ -z "$agents" ] && { echo "no agents registered in $CANARY_RINGS — nothing to autocut."; return 0; }
  echo "== canary-rollout autocut: fleet-wide dry=$dry (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    _autocut_agent "$agent" "$dry" || echo "::warning::autocut of $agent failed (continuing fleet)"
  done <<< "$agents"
  return 0
}

# ── drift: registry vs host reusables (read-only audit, #1082) ──────────────────
# canary-rings.json's .agents{} is the MANUAL source of truth for what the canary
# pipeline manages — both autocut and evaluate-all iterate `.agents | keys`, so ANY
# reusable not registered is covered by nothing (no cut, no soak, no gate, no dashboard).
# There is otherwise no scan of the hosts' .github/workflows/*-reusable.yml, so a
# first-party reusable that was added/renamed but never registered ships with ZERO staged
# rollout until a human remembers to register it.
#
# `drift` closes that observability gap: it enumerates the *-reusable.yml on every
# registered host repo, diffs against the registry's reusable paths, and REPORTS (stdout +
# job summary) two classes of drift. It is read-only — it never registers anything (ring
# topology/members need human intent); `--emit-stub` optionally prints a scaffold
# .agents[<name>] block for a maintainer to fill in.
#   - unregistered: a *-reusable.yml present on a host but absent from canary-rings.json.
#   - missing-file: a registry entry whose reusable file no longer exists on its host.

# _registered_hosts — the set of host repos to scan: the union of every agent's `host`
# and the org_infra_repos list, deduped (one repo per line).
_registered_hosts() {
  _jq -r '([.agents[]?.host // empty] + (.org_infra_repos // []))
          | map(select(. != "")) | unique | .[]'
}

# _gh_list_reusables <repo> — the full paths of *-reusable.yml files under the repo's
# .github/workflows (one per line). Reads the directory listing via the contents API and
# filters locally (mirrors _run_json: raw fetch, jq in the caller). Returns non-zero when
# the listing could NOT be enumerated (the API errored or did not return a JSON array), so
# the caller can distinguish "no reusables here" from "could not read the host" — the latter
# must NOT be treated as every registered reusable having been deleted (a false missing-file
# avalanche). A genuinely empty (but readable) workflows dir returns success with no output.
_gh_list_reusables() {
  local repo="$1" json
  json="$(gh api "repos/$repo/contents/.github/workflows" 2>/dev/null)" || return 1
  jq -e 'type=="array"' >/dev/null 2>&1 <<< "$json" || return 1
  jq -r '[.[]? | select(.type=="file") | select((.name // "") | endswith("-reusable.yml")) | .path] | .[]' \
    2>/dev/null <<< "$json" || true
  return 0
}

# _registered_reusables_for_host <host> — the reusable paths registered to <host> (one
# per line, deduped).
_registered_reusables_for_host() {
  _jq -r --arg h "$1" '[.agents[]? | select(.host==$h) | .reusable // empty] | unique | .[]'
}

# _unmanaged_reusables_for_host <host> — reusable paths on <host> INTENTIONALLY out of the
# ring-gate model, recorded in the `unmanaged` block (#651): single-hop channel reusables,
# frozen-major `@vN` infra, or dispatch-only workflows. drift excludes these so its
# "unregistered" signal only flags reusables that genuinely still need onboarding.
_unmanaged_reusables_for_host() {
  _jq -r --arg h "$1" '[.unmanaged[]? | select(.host==$h) | .reusable // empty] | unique | .[]'
}

# _agents_for_reusable <host> <path> — the registry agent name(s) whose (host,reusable)
# match, joined by ", " (for the missing-file finding message).
_agents_for_reusable() {
  _jq -r --arg h "$1" --arg p "$2" \
    '[.agents | to_entries[] | select(.value.host==$h and .value.reusable==$p) | .key] | join(", ")'
}

# _drift_scaffold <host> <path> — a scaffold .agents[<name>] JSON block for an unregistered
# reusable, keyed by the name derived from the filename (foo-reusable.yml → foo). Clones an
# existing agent's ring topology + gate defaults as a starting point (members need human
# intent), resets host/reusable/run_workflow, and empties the per-reusable benign allowlist
# so a new reusable does not silently inherit another agent's benign classes. --emit-stub only.
_drift_scaffold() {
  local host="$1" path="$2" name
  name="${path##*/}"; name="${name%-reusable.yml}"
  _jq --arg h "$host" --arg p "$path" --arg n "$name" '
    (.agents | to_entries | (map(select(.value.host==$h)) + .) | .[0].value) as $tpl
    | { ($n): ($tpl
        | .host = $h
        | .reusable = $p
        | .run_workflow = "TODO: set to the reusable workflow name (the name: value)"
        | (.gate.benign_failure_classes) = []) }'
}

# cmd_drift [--emit-stub] — the read-only registry/host drift audit. Exits 0 (report-only);
# each finding is a ::warning:: annotation and a job-summary row. --emit-stub additionally
# prints a scaffold .agents[<name>] block per unregistered reusable.
cmd_drift() {
  local emit_stub=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --emit-stub) emit_stub=true ;;
      *) echo "::error::unknown drift flag: $1" >&2; return 2 ;;
    esac; shift
  done
  echo "== canary-rollout drift: registry vs host reusables (read-only; gate standard: .github#548) =="
  local hosts host rows="" stubs="" u_total=0 m_total=0
  hosts="$(_registered_hosts)"
  if [ -z "$hosts" ]; then
    echo "no host repos resolved from $CANARY_RINGS — nothing to audit."; return 0
  fi
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    echo "──────── host: $host ────────"
    local present registered unmanaged_r unregistered missing p agents
    if ! present="$(_gh_list_reusables "$host")"; then
      # Could not read the host's workflows dir — skip it rather than false-flag every
      # registered reusable as missing-file. Read-only + best-effort: a warning, not a failure.
      echo "::warning::drift $host: could not enumerate .github/workflows (API error / no access) — skipping host this cycle"
      continue
    fi
    registered="$(_registered_reusables_for_host "$host")"
    unmanaged_r="$(_unmanaged_reusables_for_host "$host")"
    local reg_arr=() pres_arr=() um_arr=() reg_str="" pres_str="" um_str=""
    if [ -n "$registered" ]; then mapfile -t reg_arr <<< "$registered"; fi
    if [ -n "$present" ]; then mapfile -t pres_arr <<< "$present"; fi
    if [ -n "$unmanaged_r" ]; then mapfile -t um_arr <<< "$unmanaged_r"; fi
    [ "${#reg_arr[@]}" -gt 0 ] && reg_str=" ${reg_arr[*]}"
    [ "${#pres_arr[@]}" -gt 0 ] && pres_str=" ${pres_arr[*]}"
    [ "${#um_arr[@]}" -gt 0 ] && um_str=" ${um_arr[*]}"
    echo "  registered reusables (${#reg_arr[@]}):$reg_str"
    echo "  present *-reusable.yml (${#pres_arr[@]}):$pres_str"
    [ "${#um_arr[@]}" -gt 0 ] && echo "  unmanaged (intentional, out of ring gate) (${#um_arr[@]}):$um_str"
    # unregistered = present on the host, minus registered agents AND intentionally-unmanaged (#651).
    unregistered="$(set_difference "$(set_difference "$present" "$registered")" "$unmanaged_r")"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      echo "::warning::DRIFT[unregistered] $host: $p present on host but absent from canary-rings.json (no cut/soak/gate/dashboard until registered)"
      rows+="| \`$host\` | unregistered | \`$p\` | not in \`.agents{}\` — register it or delete the file |"$'\n'
      u_total=$((u_total + 1))
      if [ "$emit_stub" = true ]; then stubs+="$(_drift_scaffold "$host" "$p")"$'\n'; fi
    done <<< "$unregistered"
    # missing-file = registered in the registry but the file is gone from the host.
    missing="$(set_difference "$registered" "$present")"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      agents="$(_agents_for_reusable "$host" "$p")"
      echo "::warning::DRIFT[missing-file] $host: registry agent '${agents:-?}' -> $p not found on host (deleted/renamed reusable; stale registry entry)"
      rows+="| \`$host\` | missing-file | \`$p\` | registry agent \`${agents:-?}\` points at a file that no longer exists |"$'\n'
      m_total=$((m_total + 1))
    done <<< "$missing"
  done <<< "$hosts"

  echo "----"
  local total=$((u_total + m_total))
  echo "drift summary: $u_total unregistered, $m_total missing-file ($total total findings)"
  if [ "$total" -eq 0 ]; then
    echo "no reusable drift detected — the registry and host reusables are in sync."
  fi
  if [ "$emit_stub" = true ] && [ -n "$stubs" ]; then
    echo "---- scaffold .agents[<name>] stubs for unregistered reusables (--emit-stub) ----"
    echo "Paste into standards/canary-rings.json under .agents, then set run_workflow + review ring members:"
    printf '%s' "$stubs"
  fi

  # Render the fleet-drift table into the run's job summary (a read-only snapshot). Falls
  # back to stdout when GITHUB_STEP_SUMMARY is unset (local/manual runs).
  local ts dmd
  ts="$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo unknown)"
  if [ "$total" -eq 0 ]; then
    dmd="$(printf '# Canary Rollout — reusable drift\n\nLast updated: `%s` · gate standard: .github#548.\n\n_No reusable drift — the registry and host `*-reusable.yml` are in sync._\n' "$ts")"
  else
    dmd="$(printf '# Canary Rollout — reusable drift\n\nLast updated: `%s` · gate standard: .github#548 · findings: **%s** (%s unregistered, %s missing-file).\n\n| host | class | reusable | note |\n|---|---|---|---|\n%s\n> `unregistered` ships with ZERO staged rollout until added to `.agents{}`; `missing-file` is a stale registry entry pointing at a deleted reusable. Report-only — no auto-registration.\n' "$ts" "$total" "$u_total" "$m_total" "${rows%$'\n'}")"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '\n%s\n' "$dmd" >> "$GITHUB_STEP_SUMMARY"; then
      echo "  wrote reusable-drift table to the job summary"
    else
      echo "::warning::could not write the reusable-drift job summary"
    fi
  fi
  return 0
}

main() {
  local cmd
  for cmd in jq gh git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "::error::Required command '$cmd' is not installed." >&2
      return 1
    fi
  done
  if [ -n "${SOAK_WINDOW_DAYS:-}" ] && ! [[ "${SOAK_WINDOW_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::SOAK_WINDOW_DAYS, when set, must be a positive integer" >&2
    return 2
  fi
  local sub="${1:-}"; shift || true
  case "$sub" in
    evaluate)     [ $# -ge 1 ] || { echo "usage: evaluate <agent>" >&2; return 2; }; cmd_evaluate "$@" ;;
    evaluate-all) cmd_evaluate_all ;;
    promote)      [ $# -ge 1 ] || { echo "usage: promote <agent> [--override] [--confirm] [--allow-pre-existing] [--dry-run]" >&2; return 2; }; cmd_promote "$@" ;;
    promote-all)  cmd_promote_all "$@" ;;
    rollback)     [ $# -ge 2 ] || { echo "usage: rollback <agent> <ring> --to <vX.Y.Z>" >&2; return 2; }; cmd_rollback "$@" ;;
    resolve)      [ $# -ge 2 ] || { echo "usage: resolve <agent> <channel>" >&2; return 2; }; resolve_members "$@" ;;
    sync-issues)  cmd_sync_issues "$@" ;;   # upsert blocker issues + dashboard for held promotions
    autocut)      cmd_autocut "$@" ;;       # cut a new candidate when a reusable changes on main (#1069)
    drift)        cmd_drift "$@" ;;         # report reusables present on a host but unregistered, + stale registry entries (#1082)
    *) echo "::error::usage: canary-rollout.sh {autocut|drift|evaluate|evaluate-all|promote|promote-all|rollback|resolve|sync-issues} [args]" >&2; return 2 ;;
  esac
}

# Source-guard: tests source this file to exercise resolve_members etc. without running.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
