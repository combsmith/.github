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
# cross-repo agent (host != THIS_REPO, e.g. the #482 reusables hosted in petry-projects/
# .github) keeps its <name>/<channel> and <name>/vX.Y.Z tags on ITS host, so those tags
# must be resolved there via `gh api` — reading local refs resolves empty and the frontier
# falsely reports "fully rolled out" (#1049). Mirrors cut-release.sh's CROSS_REPO_TARGET.
THIS_REPO="${GITHUB_REPOSITORY:-petry-projects/.github-private}"

# CANARY_MAX_COMMIT_PAGES — pagination ceiling (100 commits/page) when autocut enumerates a
# commit range for bump signals. A range that cannot be fully enumerated within this many pages
# is treated as UNRESOLVABLE and fails safe to a major bump (#1023 defect 1b), never silently to
# patch. 50 pages = 5000 commits — far beyond any real inter-cut range.
CANARY_MAX_COMMIT_PAGES="${CANARY_MAX_COMMIT_PAGES:-50}"
if ! [[ "$CANARY_MAX_COMMIT_PAGES" =~ ^[0-9]+$ ]] || [ "$CANARY_MAX_COMMIT_PAGES" -le 0 ]; then
  CANARY_MAX_COMMIT_PAGES=50
fi

# CANARY_PROMOTION_FAILURE_ESCALATE_AFTER — how many CONSECUTIVE scheduled runs a tag write may
# fail before its tracking issue escalates to needs-human + dev-lead (#1023 defect 2). Default 2
# (~8h at the 4h cadence) so a single transient rejection self-heals but a stuck write escalates.
CANARY_PROMOTION_FAILURE_ESCALATE_AFTER="${CANARY_PROMOTION_FAILURE_ESCALATE_AFTER:-2}"

_jq()  { jq "$@" "$CANARY_RINGS"; }
_agent_field() { _jq -r --arg a "$1" ".agents[\$a].$2"; }

# ── hot-path lookups without forks (#1259) ───────────────────────────────────────────────────────
# _agent_run_json runs once per (agent, repo, window) — thousands of times per sweep, almost always
# inside a `$(...)` subshell. Before this, each call forked jq three times to re-parse the whole
# registry (run_workflow, the ingress workflow name, ingress_job) and twice more to hash cache keys,
# which made a non-consumer lookup ~26 ms instead of ~10 ms (measured; see #1259).
#
# Registry memo: main() calls _registry_preload ONCE in the parent shell, before the fan-out forks its
# subshells, which inherit the arrays. Outside main (tests that source this file) nothing is preloaded
# and every accessor falls back to the original jq lookup, so behaviour is identical either way.
declare -A _REG_RUN_WF=() _REG_INGRESS_JOB=()
_REG_INGRESS_WF=""; _REG_LOADED_FOR=""; _REG_VAL=""

# _registry_preload — load run_workflow, ingress_job and the ingress workflow name for every agent in a
# SINGLE jq call. The unit separator (\x1f) is non-whitespace, so `read` keeps empty fields.
_registry_preload() {
  # Invalidate first so a failed (re)load falls back to the jq lookups instead of serving a stale memo.
  _REG_LOADED_FOR=""; _REG_RUN_WF=(); _REG_INGRESS_JOB=(); _REG_INGRESS_WF=""
  local path="${CANARY_RINGS:-}" dump agent wf job iwf
  [ -n "$path" ] && [ -r "$path" ] || return 1
  # A value containing a newline or U+001F would corrupt the framing; refuse to preload (jq errors) so
  # every lookup uses the exact per-call jq path instead.
  dump="$(jq -r 'def chk: if test("[\n\u001f]") then error("delimiter in registry value") else . end;
                 ((.ingress?.workflow? // "") | tostring | chk),
                 ((.agents // {}) | to_entries[]
                  | [.key, (.value.run_workflow | tostring), ((.value.ingress_job // "") | tostring)]
                  | map(chk) | join("\u001f"))' "$path" 2>/dev/null)" || return 1
  _REG_RUN_WF=(); _REG_INGRESS_JOB=()
  { IFS= read -r iwf || true
    while IFS=$'\x1f' read -r agent wf job; do
      [ -n "$agent" ] || continue
      _REG_RUN_WF["$agent"]="$wf"; _REG_INGRESS_JOB["$agent"]="$job"
    done; } <<< "$dump"
  _REG_INGRESS_WF="${iwf:-Agent Ingress}"
  _REG_LOADED_FOR="$path"
}

# Accessors set _REG_VAL (no command substitution, so no fork). Each returns the same value as the
# jq lookup it replaces ("null" for a missing run_workflow, "" for a missing ingress_job).
_reg_loaded() { [ -n "$_REG_LOADED_FOR" ] && [ "$_REG_LOADED_FOR" = "${CANARY_RINGS:-}" ]; }
_reg_run_workflow() {
  if _reg_loaded && [[ -v _REG_RUN_WF["$1"] ]]; then _REG_VAL="${_REG_RUN_WF[$1]}"
  else _REG_VAL="$(_agent_field "$1" run_workflow)"; fi
}
_reg_ingress_job() {
  if _reg_loaded && [[ -v _REG_INGRESS_JOB["$1"] ]]; then _REG_VAL="${_REG_INGRESS_JOB[$1]}"
  else _REG_VAL="$(_jq -r --arg a "$1" '(.agents[$a].ingress_job)? // empty' 2>/dev/null || true)"; fi
}
_reg_ingress_wf() {
  if _reg_loaded; then _REG_VAL="$_REG_INGRESS_WF"
  else _REG_VAL="$(_jq -r '.ingress?.workflow? // empty' 2>/dev/null || true)"; _REG_VAL="${_REG_VAL:-Agent Ingress}"; fi
}

# _cat_file <file> — print a cache file's bytes. A small file is read in-shell (the hot case is a 2-byte "[]"
# for a repo with no such workflow: a `cat` fork per hit adds up over thousands of calls); anything bigger
# falls back to cat, because bash `read` is slower than cat on big files (measured: 670 KB, 19 ms vs 12 ms).
# `read -n 64` returns 0 only when it stopped at the limit, i.e. the file may be larger.
_cat_file() {
  local _c=""
  if IFS= read -r -d '' -n 64 _c < "$1"; then cat "$1"; else printf '%s' "$_c"; fi
}

# _cache_name <key> — set _CACHE_NAME to a filesystem-safe name for <key>, without forking for any key whose
# encoding fits in a filename (the hot path: repo/workflow names are short). It is an
# INJECTIVE byte-wise percent-encoding ([A-Za-z0-9.-] kept; every other byte, "%" and "_" included, as
# %XX), so two distinct keys can never share a cache file — the property the sha256 names gave (a plain
# char substitution would map a workflow "A B" and "A/B" on one repo to the same file and cross-
# contaminate their run history). The old name cost three forks per lookup (printf | sha256sum | cut).
# An encoding too long for a filename falls back to a sha256 prefixed "h_" (which an encoded name can
# never start with: "_" is always encoded) — that case does fork. With no hasher installed it keeps the
# full encoding instead: still injective, and a name over the filesystem limit only fails to cache.
_cache_name() {
  local LC_ALL=C
  local key="$1" out="" c i n h
  n=${#key}
  for (( i=0; i<n; i++ )); do
    c="${key:i:1}"
    case "$c" in
      [A-Za-z0-9.-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  if [ "${#out}" -gt 200 ]; then
    h="$(printf '%s' "$key" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -d' ' -f1)" || h=""
    [ -z "$h" ] || out="h_${h}"
  fi
  _CACHE_NAME="$out"
}

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

# _repo_readable <repo> — succeed when the host repository is readable. A READABLE verdict is cached
# per run in _RUNS_CACHE_DIR (shared across command-substitution subshells) so absent tags (the
# normal 404 for rings ahead of the frontier) do not each cost a second API read; an unreadable
# verdict is never cached, so a transient failure cannot stick.
_repo_readable() {
  local repo="$1" marker=""
  [ -n "${_RUNS_CACHE_DIR:-}" ] && marker="$_RUNS_CACHE_DIR/readable.${repo//\//__}"
  [ -n "$marker" ] && [ -e "$marker" ] && return 0
  gh api "repos/$repo" --jq '.full_name' >/dev/null 2>&1 || return 1
  [ -n "$marker" ] && : > "$marker" 2>/dev/null
  return 0
}

# _gh_tag_commit <repo> <tag> — echo the COMMIT sha <tag> resolves to on <repo> via the
# GitHub API, dereferencing an annotated tag object (mirrors cut-release.sh's
# gh_release_commit). Empty on any error / absent tag (never fails the caller).
# An ABSENT tag (HTTP 404) and a lookup ERROR (5xx, rate limit, network, a failed annotated-tag
# deref) both echo empty, but an error is RECORDED (#1225): "<repo> <tag>" is appended to the file
# named by _CANARY_TAG_FAIL_FLAG when armed (mirrors _CANARY_FETCH_FAIL_FLAG for run history), so
# the frontier can hold an unknown ring BLOCKED instead of reading an outage as "fully rolled out".
_gh_tag_commit() {
  local repo="$1" tag="$2" ref_info obj type err rc=0 commit _tag_unrecorded=0
  err="$(mktemp 2>/dev/null || echo /dev/null)"
  ref_info="$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[(.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Absence is an explicit HTTP 404 ONLY; any other failure is a lookup error. A 404 is also what
    # GitHub returns for a repo the App cannot access, so confirm the host stays readable before
    # accepting it as an absent tag (otherwise an inaccessible host reads as "every ring empty").
    if ! grep -qiE 'HTTP 404' "$err" 2>/dev/null; then
      _tag_lookup_failed "$repo" "$tag" "$(tr '\n' ' ' <"$err" 2>/dev/null || true)" || _tag_unrecorded=1
    elif ! _repo_readable "$repo"; then
      _tag_lookup_failed "$repo" "$tag" "404 but host repository is not readable (access lost?)" || _tag_unrecorded=1
    fi
    [ "$err" != /dev/null ] && rm -f "$err"
    [ "$_tag_unrecorded" -eq 1 ] && printf '%s\n' "$_TAG_LOOKUP_UNRECORDED"
    return 0
  fi
  [ "$err" != /dev/null ] && rm -f "$err"
  [ -z "$ref_info" ] && return 0
  read -r obj type <<< "$ref_info"
  if [ "$type" = "tag" ]; then
    # The ref EXISTS, so a failed deref is an error, never "absent".
    if commit="$(gh api "repos/$repo/git/tags/$obj" --jq '(.object?.sha // "" | tostring)' 2>/dev/null)"; then
      printf '%s\n' "$commit"
    else
      _tag_lookup_failed "$repo" "$tag" "annotated tag object $obj could not be dereferenced" \
        || printf '%s\n' "$_TAG_LOOKUP_UNRECORDED"
    fi
  else
    printf '%s\n' "$obj"
  fi
}

# _tag_lookup_failed <repo> <tag> <detail> — report a tag-lookup ERROR (not an absent tag) and
# record it to _CANARY_TAG_FAIL_FLAG when armed (#1225). Returns non-zero ONLY when the flag is armed
# but the record could not be written; the caller then emits _TAG_LOOKUP_UNRECORDED in place of the
# commit so _ring_commits still reads the ring as unknown (a swallowed write failure must never
# turn an outage into an absent tag).
_TAG_LOOKUP_UNRECORDED="!tag-lookup-error-unrecorded"
_tag_lookup_failed() {
  echo "::warning::_gh_tag_commit: could not resolve $2 on $1 (lookup error, treated as UNKNOWN — not absent): $3" >&2
  if [ -n "${_CANARY_TAG_FAIL_FLAG:-}" ]; then
    printf '%s %s\n' "$1" "$2" >> "$_CANARY_TAG_FAIL_FLAG" 2>/dev/null || return 1
  fi
  return 0
}

# _gh_write <gh-args…> — run a `gh` mutation with the repo-scoped WRITE token when one is
# provided (CANARY_WRITE_TOKEN), else the ambient GH_TOKEN. The owner-wide token the workflow
# mints for the fleet gate's cross-repo run-history reads is refused a release-channel-tags
# ruleset bypass on a protected channel-tag PATCH — 403 "Resource not accessible by
# integration" (#745): GitHub evaluates an App's bypass/effective-permissions differently for
# an owner-level token than for a repo-scoped installation token. So tag writes are routed
# through a SECOND token minted repo-scoped (repositories: .github + .github-private) with an
# explicit Contents:write, while reads keep the owner-wide token (don't regress the '*'
# stable-tier enumeration). Absent CANARY_WRITE_TOKEN (e.g. unit tests / local runs) it is a
# transparent pass-through, so every existing GH_TOKEN-only path is unchanged.
_gh_write() {
  if [ -n "${CANARY_WRITE_TOKEN:-}" ]; then
    GH_TOKEN="$CANARY_WRITE_TOKEN" gh "$@"
  else
    gh "$@"
  fi
}

# _gh_move_tag <repo> <tag> <sha> — force-move (or create) the lightweight ref
# refs/tags/<tag> on <repo> to <sha> via the GitHub API. THE channel-tag mover for every
# agent (promote + rollback), this-repo and cross-repo alike (#1076): the API path is
# granted the release-manager App's ruleset bypass for tag UPDATEs, whereas a local
# `git push --force` is not (013 on protected channel tags) and also fails with
# "nonexistent object" for a cross-repo host commit absent from this checkout (#1054).
# Tries PATCH (existing ref) then falls back to POST (create the ref).
# The operative PATCH must NOT swallow stderr (#743): a promotion-due run was failing with
# only the generic caller-side "failed to move" because both calls discarded the API error,
# hiding the real GitHub rejection (ruleset/bypass/permission). Capture the response and
# surface it as a single-line ::error::. The POST create-ref fallback is taken ONLY when the
# PATCH is a genuine 404/"not found" (the ref does not yet exist) — for any OTHER failure a
# POST would 422 "Reference already exists" and MASK the real rejection, so we stop and report.
_gh_move_tag() {
  [ $# -lt 3 ] && return 1
  local repo="$1" tag="$2" sha="$3" out rc
  out="$(_gh_write api -X PATCH "repos/$repo/git/refs/tags/$tag" \
      -f sha="$sha" -F force=true 2>&1)" && return 0
  rc=$?
  # Only a genuinely-absent ref warrants creating it; every other PATCH failure is a real
  # rejection to surface, not to paper over with a create. GitHub reports an absent ref two ways:
  # a 404 "Not Found", and — the case that took the scheduled promote-all red every 4h (#1019) —
  # a PATCH of a never-created channel tag returns 422 "Reference does not exist". Both are
  # create-if-missing signals; "Reference already exists" (a distinct 422) is NOT, so it still
  # falls through to the surfaced rejection below.
  local low="${out,,}"
  if [[ "$low" != *"not found"* && "$low" != *"http 404"* && "$low" != *"reference does not exist"* ]]; then
    # #749: on a 403 "Resource not accessible by integration" — the failure #745/#746 did NOT
    # fix — dump the write token's EFFECTIVE permissions + scope so the next step is decided
    # from data, not another guess. Only runs on the 403 branch (a non-404 that is also a
    # permission 403), before the ::error:: so the diagnostic and the surfaced rejection are
    # co-located in the run log. Best-effort: never alters rc.
    if [[ "$low" == *"403"* || "$low" == *"not accessible by integration"* ]]; then
      _gh_403_diag "$repo" >&2 || true
    fi
    echo "::error::_gh_move_tag: could not move refs/tags/$tag -> ${sha:0:12} on $repo (HTTP): ${out//$'\n'/ }" >&2
    return "$rc"
  fi
  out="$(_gh_write api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$sha" 2>&1)" && return 0
  rc=$?
  echo "::error::_gh_move_tag: could not create refs/tags/$tag -> ${sha:0:12} on $repo (HTTP): ${out//$'\n'/ }" >&2
  return "$rc"
}

# _gh_403_diag <repo> — one-shot effective-permission diagnostic (#749), called only from the
# _gh_move_tag 403 failure path. #745/#746 (repo-scoped write token) did NOT resolve the 403
# "Resource not accessible by integration" on a protected channel-tag PATCH, so before guessing
# again we DUMP DATA, using the SAME token the PATCH used (_gh_write → CANARY_WRITE_TOKEN when
# set). This distinguishes the two possible root causes:
#   (a) the token LACKS effective contents:write → a minting bug (code-fixable), or
#   (b) the token HAS contents:write but the release-channel-tags ruleset bypass lapsed → NOT a
#       code bug (a maintainer must re-save bypass_actors / open GitHub support).
# Emits, to stderr, inside a foldable ::group:::
#   - X-Accepted-GitHub-Permissions from `gh api -i repos/<repo>` (the perms the API advertises),
#   - total_count from /installation/repositories (how many repos the installation token covers).
# Best-effort: every probe is guarded, and the function always returns 0 — a diagnostic must
# never mask the 403 or change the mover's exit status.
_gh_403_diag() {
  local repo="$1" hdr inst count=""
  echo "::group::_gh_move_tag 403 effective-permission diagnostic (#749)"
  if [ -n "${CANARY_WRITE_TOKEN:-}" ]; then
    echo "diag: introspecting with CANARY_WRITE_TOKEN (repo-scoped write token)"
  else
    echo "diag: introspecting with ambient GH_TOKEN (no CANARY_WRITE_TOKEN set)"
  fi
  # (1) What permission does the API advertise for this repo endpoint?
  hdr="$(_gh_write api -i "repos/$repo" 2>/dev/null | grep -i '^x-accepted-github-permissions:' || true)"
  if [ -n "$hdr" ]; then
    printf 'diag: %s\n' "${hdr%$'\r'}"
  else
    echo "diag: X-Accepted-GitHub-Permissions header not present on repos/$repo response"
  fi
  # (2) How many repositories does the installation token cover?
  inst="$(_gh_write api /installation/repositories 2>/dev/null || true)"
  if [ -n "$inst" ]; then
    count="$(jq -r '.total_count? // empty' <<<"$inst" 2>/dev/null || true)"
  fi
  if [ -n "$count" ]; then
    echo "diag: installation/repositories total_count=${count}"
  else
    echo "diag: installation/repositories total_count=<unreadable>"
  fi
  echo "::endgroup::"
  return 0
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
  obj="$(_gh_write api -X POST "repos/$repo/git/tags" \
      -f tag="$tag" -f message="$message" -f object="$sha" -f type=commit \
      --jq '.sha // empty')"
  if [ $? -ne 0 ] || [ -z "$obj" ]; then
      echo "::error::_gh_create_annotated_tag: could not create the annotated release tag on $repo or read back its object SHA" >&2
      return 1
  fi
  _gh_write api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$obj" >/dev/null 2>&1 || {
      echo "::error::_gh_create_annotated_tag: created tag object $obj on $repo but could not publish ref refs/tags/$tag" >&2
      return 1
  }
}

# _agent_current_major <agent> — the MAJOR of the agent's highest vX.Y.Z release on its
# host, empty if none (major-scoped-channels epic #657, Phase F4). This is the "current
# major line" a v-scoped channel tag is derived against; there is no new registry field —
# it is derived from the release tags already present (mirrors _next_release_version).
# This is the RELEASE major and MUST NOT be used to resolve channel-scoped tags: a
# release-v14 / channel-v1 agent (v14 line not yet migrated to channel tags) would key on a
# nonexistent `v14-<tier>` line. Use _agent_current_channel_major for channel resolution (#1065).
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

# _agent_has_channel_major <agent> <major> — return 0 iff the agent's v-scoped channel line
# for <major> has been ESTABLISHED, signalled by the presence of its anchor tag
# `<agent>/v<M>-next`. A major line is always seeded at `next` (autocut opens `v<M>-next` on a
# major bump, #657 F4) and then extended tier-by-tier by promotion, so `v<M>-next` existing is
# the "has a channel major" test — distinct from merely having a vX.Y.Z RELEASE (the legacy
# bare-only fleet has releases but no v-scoped channel tags). Non-zero when the anchor is absent
# or <major> is empty, so resolution for such agents stays byte-identical to pre-F4.
_agent_has_channel_major() {
  local agent="$1" major="$2"
  [ -n "$major" ] || return 1
  _looks_like_oid "$(_channel_tag_commit "$agent" "v${major}-next")"
}

# _agent_current_channel_major <agent> — the highest MAJOR M for which the agent's v-scoped
# channel line has been ESTABLISHED, i.e. the `<agent>/v<M>-next` anchor exists; empty for the
# legacy bare-only fleet (no anchor). This is the CHANNEL major, distinct from _agent_current_major
# (the RELEASE major): a release-v14 / channel-v1 agent resolves to 1 here, so channel resolution
# targets the tags that actually exist (`v1-<tier>`) and never keys on a tagless `v14-<tier>` line
# (#1065). Derived from the same anchors _agent_has_channel_major probes: _host_release_versions
# strips `refs/tags/<agent>/v`, emitting `1-next` alongside `1.0.0`, so the `v<M>-next` anchors
# surface as `<M>-next` lines here.
declare -A _AGENT_CHANNEL_MAJOR_CACHE=()

_agent_current_channel_major() {
  local agent="$1"
  if [[ -v _AGENT_CHANNEL_MAJOR_CACHE["$agent"] ]]; then
    echo "${_AGENT_CHANNEL_MAJOR_CACHE["$agent"]}"
    return 0
  fi
  local major
  major="$(_host_release_versions "$agent" | sed -n 's/^\([0-9][0-9]*\)-next$/\1/p' | sort -n | tail -1)"
  _AGENT_CHANNEL_MAJOR_CACHE["$agent"]="$major"
  echo "$major"
}

# _resolved_channel <agent> <tier> — echo "<tag>\t<commit>" for the channel <agent> uses on
# <tier> (major-scoped-channels epic #657, Phase F4). When the agent has an ESTABLISHED channel
# major (its `v<M>-next` anchor exists) the v-scoped `<agent>/v<M>-<tier>` line is AUTHORITATIVE:
# resolve to it and DO NOT fall back to the bare tier when this tier's v-scoped tag is absent —
# its commit is simply empty, which makes the frontier treat the tier as not-yet-reached and a
# promotion CREATE the tag (#1065 AC1′). The old fallback stranded the v-line at the tier it was
# first seeded at, silently masking the gap until a stub deploy pinned a nonexistent ref. An
# agent with no channel major at all (the legacy bare-only fleet, which may still carry a vX.Y.Z
# release) keeps using the bare tier tag — byte-identical to pre-F4.
_resolved_channel() {
  local agent="$1" tier="$2" major tag suffix
  major="$(_agent_current_channel_major "$agent")"
  if _agent_has_channel_major "$agent" "$major"; then
    tag="$(channel_tag "$agent" "$tier" "$major")"; suffix="${tag#"$agent"/}"
    printf '%s\t%s\n' "$tag" "$(_channel_tag_commit "$agent" "$suffix")"
    return 0
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

# _ring_commits <agent> [<chans_csv>] — resolve every ring's commit once, one line per ring in
# order: "<channel> <commit|-> <unknown>" (#1225). unknown=1 when a tag lookup for that ring
# ERRORED (5xx / rate limit / network — recorded by _gh_tag_commit via _CANARY_TAG_FAIL_FLAG),
# as opposed to a genuinely ABSENT tag (404, unknown=0 with commit "-"), which keeps the legacy
# semantics (#1118 AC6). If the per-ring flag cannot be armed the ring is reported unknown (fail
# closed). Local-git agents have no API failure mode, so they are never unknown.
_ring_commits() {
  local agent="$1" chans="${2:-}" flag ch c u
  [ -n "$chans" ] || chans="$(ordered_channels "$agent")"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  flag="$(mktemp 2>/dev/null || true)"
  for ch in "${chan_array[@]}"; do
    u=0
    if [ -n "$flag" ] && : > "$flag" 2>/dev/null; then
      # Drop the (subshell-local) lookup cache first: an earlier UNARMED failed lookup may have
      # cached an empty commit, which would skip the API call, leave the flag empty, and read an
      # outage as an absent tag (unknown=0).
      c="$(_CHANNEL_COMMIT_CACHE=(); _AGENT_CHANNEL_MAJOR_CACHE=(); _CANARY_TAG_FAIL_FLAG="$flag" channel_commit "$agent" "$ch" || true)"
      [ -s "$flag" ] && u=1
      if [[ "$c" == *"$_TAG_LOOKUP_UNRECORDED"* ]]; then c=""; u=1; fi
    else
      c="$(channel_commit "$agent" "$ch" || true)"; u=1
      [[ "$c" == *"$_TAG_LOOKUP_UNRECORDED"* ]] && c=""
    fi
    printf '%s %s %s\n' "$ch" "${c:--}" "$u"
  done
  [ -n "$flag" ] && rm -f "$flag"
  return 0
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
#
# matching-refs/tags/<agent>/v matches EVERY <agent>/v… ref by prefix, so it also returns
# the v-scoped channel tags <agent>/v<M>-<tier> — which are lightweight (type=commit) and
# always point at a real commit. Because "-" (0x2D) sorts before "." (0x2E), such a channel
# tag precedes the release <agent>/v<M>.<m>.<p> and, when it points at the candidate commit,
# used to match first with an empty tagger date — wedging the gate at BLOCKED indeterminate
# (#1046). So every ref is filtered to a strict release suffix before it can match; a channel
# tag (or any other non-release <agent>/v… ref) is skipped, never the shadow of a release.
_gh_candidate_cut_date() {
  local repo="$1" agent="$2" commit="$3" ref obj type csha cdate
  while IFS=$'\t' read -r ref obj type; do
    [ -z "$obj" ] && continue
    _is_release_tag_suffix "${ref#refs/tags/"$agent"/}" || continue
    if [ "$type" = "tag" ]; then
      IFS=$'\t' read -r csha cdate < <(gh api "repos/$repo/git/tags/$obj" \
        --jq '[(.object?.sha // "" | tostring), (.tagger?.date // "" | tostring)] | @tsv' 2>/dev/null) || true
    else
      csha="$obj"; cdate=""
    fi
    if [ "$csha" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(gh api "repos/$repo/git/matching-refs/tags/$agent/v" \
             --paginate \
             --jq '.[]? | [.ref, (.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)
  echo ""
}

# candidate_cut_date <agent> <candidate_commit> — ISO-8601 Zulu tagger date of the
# immutable release tag <agent>/vX.Y.Z that points at the candidate commit. This is the
# per-candidate cumulative-window start (#548): health is measured since the candidate's
# OWN cut, NOT a rolling window — so a pre-cut failure of a prior version is excluded.
# For a cross-repo agent (host != THIS_REPO) the release tags live on the host, so the
# date is resolved there via the GitHub API instead of the local for-each-ref (#1049).
#
# The local glob refs/tags/<agent>/v* also matches the v-scoped channel tags
# <agent>/v<M>-<tier>, and for-each-ref sorts them before the release <agent>/v<M>.<m>.<p>
# ("-" < "."). A channel tag is lightweight, so its %(*objectname) is empty and its
# %(creatordate) is the COMMIT date — the same-repo counterpart of the #1046 shadow: the
# path silently reported the candidate's commit date instead of the release's tagger date.
# Refs are filtered to a strict release suffix, and only the annotated tag's dereferenced
# commit + %(creatordate) (its tagger date) is used — a lightweight ref's commit date is
# never substituted. The final fallback is the candidate commit's own date, unchanged.
candidate_cut_date() {
  local agent="$1" commit="$2" host ref deref cdate
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    _gh_candidate_cut_date "$host" "$agent" "$commit"
    return 0
  fi
  while IFS='|' read -r ref _ deref cdate; do
    _is_release_tag_suffix "${ref#refs/tags/"$agent"/}" || continue
    [ -z "$deref" ] && continue   # lightweight release-named tag — no tagger date to trust
    if [ "$deref" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(git for-each-ref \
             --format='%(refname)|%(objectname)|%(*objectname)|%(creatordate:iso-strict)' \
             "refs/tags/${agent}/v*" 2>/dev/null)
  # Last resort: the local commit date. %cI keeps the committer's offset, so normalise it to Zulu like
  # every other source — the window filters compare timestamps as strings (#1244 item 17).
  _to_z "$(git log -1 --format=%cI "$commit" 2>/dev/null || true)"
}

# _gh_err_summary <stderr-text> — condense gh's stderr into a single line for the
# ::warning::/::error:: annotations so an operator can tell WHY a read failed (#810):
# a 403 secondary-rate-limit throttle, an auth failure, a transient 5xx, or a network
# blip demand very different responses. Emits "HTTP <status> <class>: <reason>" (or
# just "<class>: <reason>" when no HTTP status is present). Never fails.
_gh_err_summary() {
  local err="$1" status="" class reason="" lc line
  if [[ "$err" =~ HTTP[/\ ]?([0-9]{3}) ]]; then status="${BASH_REMATCH[1]}"; fi
  lc="${err,,}"
  if [[ "$lc" == *"secondary rate limit"* ]]; then class="secondary-rate-limit"
  elif [[ "$lc" == *"rate limit"* ]]; then class="rate-limit"
  elif [ "$status" = "401" ] || [[ "$lc" == *"bad credentials"* ]] || [[ "$lc" == *"requires authentication"* ]]; then class="auth"
  elif [ -n "$status" ] && [ "$status" -ge 500 ]; then class="server-error"
  elif [ "$status" = "403" ]; then class="forbidden"
  elif [ -n "$status" ] && [ "$status" -ge 400 ]; then class="client-error"
  else class="network-or-unknown"; fi
  # first non-blank line of gh's stderr, trimmed, capped so an annotation stays readable
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ -n "${line//[[:space:]]/}" ]; then reason="$line"; break; fi
  done <<< "$err"
  reason="${reason:0:200}"
  if [ -n "$status" ]; then printf 'HTTP %s %s: %s' "$status" "$class" "$reason"
  else printf '%s: %s' "$class" "$reason"; fi
}

# _gh_retry_after <stderr-text> — seconds to wait per an EXPLICIT throttle hint gh
# surfaced (#810): a `Retry-After: N` header echo, a bare "retry after Ns", or an
# `x-ratelimit-reset: <epoch>` we convert to a delta from now. Empty when none —
# the caller then falls back to exponential+jittered backoff. Honoring the server's
# own hint avoids hammering a secondary-rate-limit window and getting throttled harder.
_gh_retry_after() {
  local err="$1" lc="${1,,}" secs="" now
  if [[ "$lc" =~ retry[-\ ]?after:?[\ ]*([0-9]+) ]]; then
    secs="${BASH_REMATCH[1]}"
  elif [[ "$lc" =~ x-ratelimit-reset:?[\ ]*([0-9]+) ]]; then
    now="$(date +%s)"; secs=$(( BASH_REMATCH[1] - now )); [ "$secs" -lt 0 ] && secs=0
  fi
  printf '%s' "$secs"
}

# _repo_wf_runs_cached <repo> <workflow> — ALL recent runs of one workflow on a repo
# (conclusion,createdAt,databaseId,workflowName), UNBOUNDED by date and memoized for the
# process, so the candidate / baseline / downgrade / correctness windows a single agent
# samples collapse from one `gh run list` per (repo × workflow × window) into ONE read
# per (repo × workflow) (#819). This is the fix for the secondary-rate-limit burst AND
# for the retry storm it caused: a workflow that has never run on a repo makes `gh run
# list --workflow` exit non-zero with "could not find any workflows named …" — a PERMANENT
# condition, not a transient one, so retrying it 6× with backoff (as #810's wrapper did
# for every error class) blew a fleet sweep out to ~20 min and got the job cancelled. We
# now classify that message as a legitimate empty result ([]) and never retry it; only a
# genuine transport error (403/5xx/network/auth) is retried and, if sustained, fails CLOSED.
#
# The cache is FILE-backed under $_RUNS_CACHE_DIR (exported by main() before the fan-out),
# because callers invoke this via command substitution — a subshell — so an in-memory array
# populated in one call would not survive to the next. When the dir is unset (a unit test
# calling _run_json directly), every call fetches. Tunable via CANARY_GH_RETRIES /
# CANARY_GH_RETRY_SLEEP (tests set 0). CANARY_GH_RETRY_AFTER_CAP caps server hints (default 900s).
#
# Optional 5th arg `from` (YYYY-MM-DD, #1259): bound the list server-side with `--created ">=<from>"`.
# Used for the ingress list, whose newest-5000 read pages through ~50 pages per repo (~10 s each call)
# although every window the gate samples starts at most ~2 weeks back (see _ingress_horizon).
#
# Optional 3rd arg `strict` (#1224): when "1", a not-found workflow returns [] with exit 3
# instead of 0, so the caller can tell "this repo has no such workflow" from "it has the
# workflow but no runs" — the signal that a repo may be ADR-0007-collapsed. The not-found
# verdict is cached alongside the [] (a `.nf` marker) so a strict cache hit still reports it.
_repo_wf_runs_cached() {
  local repo="$1" wf="$2" strict="${3:-0}" limit="${4:-1000}" from="${5:-}" out err summary ra delay span expo errfile cachef key
  local attempts="${CANARY_GH_RETRIES:-6}" base="${CANARY_GH_RETRY_SLEEP:-2}" attempt=1
  local ra_cap="${CANARY_GH_RETRY_AFTER_CAP:-900}"
  case "$ra_cap" in ''|*[!0-9]*) ra_cap=900 ;; esac
  case "$attempts" in ''|*[!0-9]*) attempts=6 ;; esac
  case "$base" in ''|*[!0-9]*) base=2 ;; esac
  # Cache hit? A non-empty cache file for this (repo, workflow) — including a cached "[]"
  # for a no-runs / not-found workflow, so it is never re-queried within the sweep.
  if [ -n "${_RUNS_CACHE_DIR:-}" ]; then
    # Encode the (repo, workflow, limit) key into the filename so distinct keys can never collide
    # (see _cache_name: injective, and fork-free for names that fit in a filename, #1259). A plain
    # char-substitution would map a workflow "A B" and "A/B" on one repo to the same file and
    # cross-contaminate their run history. The run limit is part of the key: a shorter list cached for
    # the default limit must never serve the ingress read that asks for more runs.
    key="${repo}//${wf}//${limit}"
    [ -z "$from" ] || key+="//${from}"   # a date-bounded list is a different list from the unbounded one
    _cache_name "$key"
    cachef="$_RUNS_CACHE_DIR/${_CACHE_NAME}.json"
    if [ -s "$cachef" ]; then
      _cat_file "$cachef"
      [ "$strict" = "1" ] && [ -e "${cachef}.nf" ] && return 3
      return 0
    fi
  fi
  local -a cargs=()
  [ -z "$from" ] || cargs=(--created ">=$from")
  errfile="$(mktemp)"
  declare -p tmpfiles &>/dev/null || declare -g -a tmpfiles=()
  tmpfiles+=("$errfile")
  # Register the cleanup in THIS (sub)shell: command substitution forks a subshell that
  # does NOT inherit the parent's traps, so registering only on first declaration of
  # tmpfiles would leave every subshell invocation without one. Re-running `trap … EXIT`
  # in the same shell just reinstalls the same idempotent handler.
  trap 'rm -f "${tmpfiles[@]+"${tmpfiles[@]}"}"' EXIT
  while :; do
    if out="$(gh run list --repo "$repo" --workflow "$wf" \
        -L "$limit" "${cargs[@]+"${cargs[@]}"}" --json conclusion,createdAt,databaseId,workflowName 2>"$errfile")"; then
      out="${out:-[]}"
      # A 2xx whose body is not a JSON array (an error object, HTML from a proxy) is a failed fetch,
      # not "no runs": passed through, the legacy per-role reducer maps it to [] and reads it as "no
      # caller" (#1244 item 15). Fall into the retry / fail-closed path below instead.
      if jq -e 'type == "array"' >/dev/null 2>&1 <<< "$out"; then
        rm -f "$errfile"
        [ -n "${cachef:-}" ] && [ -d "$_RUNS_CACHE_DIR" ] && printf '%s' "$out" > "$cachef" 2>/dev/null || true
        printf '%s\n' "$out"; return 0
      fi
      printf '%s\n' "unexpected non-array run list body" > "$errfile"
    fi
    err=""
    if [ -r "$errfile" ]; then
      err="$(<"$errfile")"
    fi
    # A workflow with no runs on this repo is NOT a fetch failure — `gh` just can't resolve
    # the name. Treat it as an empty result (and cache []) so it is neither retried nor
    # counted as an outage; retrying it was the #810→#803 cancellation storm.
    if [[ "${err,,}" == *"could not find any workflow"* ]] || [[ "${err,,}" == *"no workflows"* ]]; then
      rm -f "$errfile"
      # Marker FIRST, then the cached []: a concurrent strict reader that sees the cache file is
      # guaranteed to see the .nf marker too (it never reads "workflow exists, no runs").
      [ -n "${cachef:-}" ] && [ -d "$_RUNS_CACHE_DIR" ] && : > "${cachef}.nf" 2>/dev/null && printf '%s' '[]' > "$cachef" 2>/dev/null || true
      echo '[]'
      [ "$strict" = "1" ] && return 3
      return 0
    fi
    summary="$(_gh_err_summary "$err")"
    if [ "$attempt" -ge "$attempts" ]; then
      echo "::error::_run_json: failed to fetch run list for $repo (workflow=$wf) after $attempts attempt(s) — $summary" >&2
      # Record the fetch failure for the sync-issues resilience layer (#820). A sustained
      # outage does NOT cleanly abort the caller (command substitutions don't inherit errexit),
      # so _frontier_state can limp on and emit a misleadingly-clean line; a file flag survives
      # the subshell and lets _frontier_state_resilient know the data is a partial/failed fetch.
      # No-op unless sync-issues armed the flag, so every other read path is unchanged.
      [ -n "${_CANARY_FETCH_FAIL_FLAG:-}" ] && printf '%s\n' "$repo" >> "$_CANARY_FETCH_FAIL_FLAG" 2>/dev/null || true
      rm -f "$errfile"; return 1
    fi
    # Prefer the server's explicit throttle hint; otherwise exponential + full jitter.
    ra="$(_gh_retry_after "$err")"
    if [ -n "$ra" ] && [ "$ra" -gt 0 ]; then
      delay="$ra"
      [ "$delay" -gt "$ra_cap" ] && delay="$ra_cap"   # honor hint but cap runaway values
    else
      expo=$((attempt - 1)); [ "$expo" -gt 20 ] && expo=20     # guard the exponent from overflow
      delay=$(( base << expo ))
      span=$(( delay - base )); [ "$span" -lt 0 ] && span=0
      delay=$(( base + RANDOM % (span + 1) ))                    # full jitter in [base, delay]
      [ "$delay" -gt 30 ] && delay=30
    fi
    echo "::warning::_run_json: transient failure fetching run list for $repo (workflow=$wf), attempt $attempt/$attempts — $summary — retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# _run_json <repo> <workflow> <since_z> — the target workflow's runs on a repo since the
# given Zulu timestamp, filtered LOCALLY from the per-(repo,workflow) cache so the several
# windows an agent samples share one fetch (#819). Empty repo/wildcard → []. A genuine
# fetch failure fails CLOSED (non-zero) so an empty [] never masks real failures and
# green-lights a bad promotion. Empty since = no lower bound.
_run_json() {
  local repo="$1" wf="$2" since="$3" raw
  if [ -z "$repo" ] || [ "$repo" = '*' ]; then echo '[]'; return 0; fi
  raw="$(_repo_wf_runs_cached "$repo" "$wf")" || return 1
  # Local since cut, inclusive — the same window the old server-side `--created ">=$since"`
  # produced. jq on an empty/garbage payload falls back to [].
  jq -c --arg since "$since" \
    '[ .[]? | select($since == "" or (.createdAt // "") >= $since) ]' \
    <<< "${raw:-[]}" 2>/dev/null || echo '[]'
}

# ── ADR-0007 collapsed repos: attribute runs by ingress JOB (#1224) ──────────────────
# A collapsed repo folds its per-role Class-1 caller stubs into ONE `Agent Ingress` workflow
# with one job per role, so `gh run list --workflow "<run_workflow>"` finds nothing there. The
# agent's runs are then the ingress runs in which its role job (registry `ingress_job`) ran.
#
# DELIBERATE DUPLICATION: the per-run role reduction below mirrors .github-private's
# scripts/lib/run-attribution.sh `normalize_ingress_runs` (#1727) — role = job-name segment
# before " / ", worst-outcome precedence across a role's jobs, an all-skipped role did not run,
# a run with no jobs is never silently dropped. It is NOT importable: this engine runs from a
# .github checkout with no .github-private tree (the same constraint as the inline autocut,
# #613/#1069). Keep the two in step if the attribution rules change.

# ── CANARY_TIMING: where does a sweep spend its time? (#1259) ───────────────────────────────────────
# CANARY_TIMING=1 forces it on, 0 forces it off; unset ("auto") it is on only for scheduled and
# workflow_dispatch runs in GitHub Actions, so test and pull_request runs are untouched. When on,
# `gh` is wrapped in a function (inherited by every command-substitution subshell) that appends
# "<start>\t<end>\t<gh subcommand>" per call to a file, and _agent_run_json counts its calls. At exit
# the parent prints one summary: wall time, time spent inside gh vs. in this script, calls by kind
# and the slowest ones. Everything is best-effort and never changes the exit status.
_timing_enabled() {
  case "${CANARY_TIMING:-auto}" in
    1|true|on) return 0 ;;
    0|false|off) return 1 ;;
  esac
  [ "${GITHUB_ACTIONS:-}" = "true" ] || return 1
  case "${GITHUB_EVENT_NAME:-}" in schedule|workflow_dispatch) return 0 ;; esac
  return 1
}

_timing_start() {
  _timing_enabled || return 0
  [ -n "${EPOCHREALTIME:-}" ] && [ -n "${_RUNS_CACHE_DIR:-}" ] && [ -d "$_RUNS_CACHE_DIR" ] || return 0
  _TIMING_LOG="$_RUNS_CACHE_DIR/.gh-timing.$$.tsv"; _TIMING_CALLS="$_RUNS_CACHE_DIR/.agent-run-calls.$$"
  : > "$_TIMING_LOG" 2>/dev/null || { unset _TIMING_LOG _TIMING_CALLS; return 0; }
  : > "$_TIMING_CALLS" 2>/dev/null || true
  _TIMING_T0="$EPOCHREALTIME"
  gh() {
    local t0="$EPOCHREALTIME" rc=0
    command gh "$@" || rc=$?
    _timing_kind "$@"
    printf '%s\t%s\t%s\n' "$t0" "$EPOCHREALTIME" "$_TIMING_KIND" >> "$_TIMING_LOG" 2>/dev/null || true
    return "$rc"
  }
}

# Group calls by kind: "<cmd> <subcmd>", and for `gh api` the endpoint with owner/repo and the trailing id
# (tag, run id, ...) dropped, so per-tag lookups share a row instead of each becoming its own.
_timing_kind() {
  _TIMING_KIND="${1:-} ${2:-}"
  if [ "${1:-}" = run ] && [ "${2:-}" = list ]; then
    # Which list is slow: the workflow, the -L cap and whether it was date-bounded (#1259).
    local w="" l="" b="" a prev=""
    for a in "$@"; do
      case "$prev" in --workflow) w="$a" ;; -L|--limit) l="$a" ;; --created) b=" bounded" ;; esac
      prev="$a"
    done
    _TIMING_KIND="run list [${w:-?}] L=${l:-default}$b"
    return 0
  fi
  [ "${1:-}" = api ] || return 0
  shift
  local a skip=0 p
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      -X|-H|-f|-F|-q|-t|--method|--header|--field|--raw-field|--jq|--template) skip=1; continue ;;
      -*) continue ;;
    esac
    a="${a%%\?*}"; a="${a#/}"
    IFS=/ read -r -a p <<< "$a"
    # repos/<o>/<r>/<resource>[/<sub>[/<id>...]]: keep the resource, and the sub-resource only when an id
    # follows it (so repos/o/r/commits/<sha> and .../contents/<path> collapse to one row each).
    if [ "${#p[@]}" -ge 6 ] && [ "${p[3]:-}" != contents ]; then _TIMING_KIND="api ${p[0]:-}/${p[3]:-}/${p[4]:-}"
    else _TIMING_KIND="api ${p[0]:-}/${p[3]:-}"; fi
    return 0
  done
}

_timing_report() {
  [ -n "${_TIMING_LOG:-}" ] && [ -f "$_TIMING_LOG" ] || return 0
  local calls=0 raw head kinds out
  [ -f "${_TIMING_CALLS:-}" ] && calls="$(wc -c < "$_TIMING_CALLS" 2>/dev/null | tr -d ' ')"
  raw="$(awk -F'\t' -v t0="${_TIMING_T0:-0}" -v t1="${EPOCHREALTIME:-0}" -v calls="${calls:-0}" -v subcmd="${_TIMING_SUB:-?}" '
    function f(x) { gsub(",", ".", x); return x + 0 }
    { d = f($2) - f($1); n++; sum += d; k[$3]++; ks[$3] += d; if (d > mx[$3]) mx[$3] = d }
    END {
      wall = f(t1) - f(t0); if (wall < 0.001) wall = 0.001
      printf "H\t0\tcanary timing [%s]: wall=%.0fs gh_calls=%d gh_time=%.0fs (%.0f%% of wall) script_time=%.0fs agent_run_json_calls=%s\n", subcmd, wall, n, sum, 100 * sum / wall, wall - sum, calls
      for (c in k) printf "K\t%.3f\t  %-22s calls=%-5d total=%7.1fs avg=%6.2fs max=%6.1fs\n", ks[c], c, k[c], ks[c], ks[c] / k[c], mx[c]
    }' "$_TIMING_LOG" 2>/dev/null)" || return 0
  head="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="H"{print $3}')"
  [ -n "$head" ] || return 0
  kinds="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="K"' | sort -t$'\t' -k2,2 -rn | cut -f3 | head -12)"
  out="$head"; [ -n "$kinds" ] && out="$head"$'\n'"$kinds"
  printf '%s\n' "$out" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '\n<details><summary>canary timing (%s)</summary>\n\n```\n%s\n```\n</details>\n' "${_TIMING_SUB:-?}" "$out" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
  return 0
}

# _ingress_workflow — the collapsed ingress workflow's display name (registry `.ingress.workflow`).
_ingress_workflow() {
  _reg_ingress_wf; printf '%s' "$_REG_VAL"
}

# _record_unresolved <agent> <repo> <reason> — note a ring member whose runs could not be
# attributed. Appends "<repo>\t<reason>" to $_CANARY_UNRESOLVED_FLAG (armed by _frontier_state)
# and warns once per distinct entry. A file, not a var: callers run in subshells.
_record_unresolved() {
  local agent="$1" repo="$2" reason="$3" line
  line="$(printf '%s\t%s' "$repo" "$reason")"
  if [ -n "${_CANARY_UNRESOLVED_FLAG:-}" ]; then
    grep -qxF -- "$line" "$_CANARY_UNRESOLVED_FLAG" 2>/dev/null && return 0
    # A failed append (temp fs full) must not leave a clean-looking empty flag: remove it, so the
    # gate sees the flag GONE and fails closed (see the "evidence write failed" check in _frontier_state).
    # If the cleanup fails too (read-only fs) the empty flag survives; _pair_state re-probes its
    # writability and fails closed in that case.
    printf '%s\n' "$line" >> "$_CANARY_UNRESOLVED_FLAG" 2>/dev/null || rm -f "$_CANARY_UNRESOLVED_FLAG" 2>/dev/null \
      || echo "::error::canary: cannot record or remove the unresolved-member flag '$_CANARY_UNRESOLVED_FLAG'; the gate will fail closed" >&2
  fi
  echo "::warning::canary: UNRESOLVED member $repo for '$agent' — $reason" >&2
}

# _unresolved_flag_path <agent> <cand> — per-process UNRESOLVED flag path, so concurrent
# invocations for the same agent/candidate never truncate each other's evidence.
_unresolved_flag_path() {
  printf '%s/.canary-unresolved-%s-%s-%s.txt' "${TMPDIR:-/tmp}" "$$" "$1" "$2"
}

# _run_jobs_json <repo> <run_id> — `gh run view --json jobs` for one run, file-memoized under
# $_RUNS_CACHE_DIR (an ingress run is shared by every collapsed role, so each run's jobs are read
# once per sweep). Bounded retry (CANARY_GH_RETRIES, default 6; an optional 3rd arg caps the attempts —
# the legacy single-call readers pass 1, preserving their pre-#1224 "one call, fail fast" behavior).
# Returns 0 on success; 2 when the run is permanently gone/unreadable
# (deleted or expired — HTTP 404); 1 when the jobs endpoint stayed unreadable after the full backoff
# (a transient/systemic failure — callers use that to stop reading, see _ingress_agent_runs).
_run_jobs_json() {
  local repo="$1" id="$2" cachef="" out attempt=1
  local attempts="${3:-${CANARY_GH_RETRIES:-6}}" base="${CANARY_GH_RETRY_SLEEP:-2}" delay span expo
  case "$attempts" in ''|*[!0-9]*) attempts=6 ;; esac
  case "$base" in ''|*[!0-9]*) base=2 ;; esac
  [ "$attempts" -lt 1 ] && attempts=1
  if [ -n "${_RUNS_CACHE_DIR:-}" ]; then
    _cache_name "jobs//${repo}//${id}"
    cachef="$_RUNS_CACHE_DIR/${_CACHE_NAME}.jobs.json"
    if [ -s "$cachef" ]; then
      _cat_file "$cachef"; return 0
    fi
  fi
  local errf; errf="$(mktemp 2>/dev/null || echo /dev/null)"
  while :; do
    if out="$(gh run view "$id" --repo "$repo" --json jobs 2>"$errf")" && jq -e '.jobs|type=="array"' >/dev/null 2>&1 <<< "$out"; then
      [ "$errf" != /dev/null ] && rm -f "$errf"
      [ -n "$cachef" ] && [ -d "$_RUNS_CACHE_DIR" ] && printf '%s' "$out" > "$cachef" 2>/dev/null || true
      printf '%s\n' "$out"; return 0
    fi
    # A run deleted/expired since `gh run list` is permanent — fail fast, don't burn the backoff.
    if grep -qiE 'could not find (any )?(workflow )?run|HTTP 404|run [0-9]+ not found' "$errf" 2>/dev/null; then
      [ "$errf" != /dev/null ] && rm -f "$errf"; return 2
    fi
    if [ "$attempt" -ge "$attempts" ]; then [ "$errf" != /dev/null ] && rm -f "$errf"; return 1; fi
    # Same policy as the run-list path: exponential backoff with full jitter in [base, 30s].
    expo=$((attempt - 1)); [ "$expo" -gt 20 ] && expo=20
    delay=$(( base << expo )); span=$(( delay - base )); [ "$span" -lt 0 ] && span=0
    delay=$(( base + RANDOM % (span + 1) )); [ "$delay" -gt 30 ] && delay=30
    sleep "$delay"; attempt=$((attempt + 1))
  done
}

# _ingress_horizon <since_z> — set _INGRESS_FROM (no stdout, no fork beyond one `date`) to the oldest
# date (YYYY-MM-DD, UTC) the ingress run list must reach to cover a window starting at <since_z>, or ""
# for "no bound" (empty/unparseable since, or older than the largest tier). The horizon snaps to a few
# fixed tiers (CANARY_INGRESS_HORIZON_TIERS, days, default "8 15"; set it EMPTY to disable the bound: the candidate/correctness windows and
# the 14-day baseline) so the run lists a sweep reads are shared across windows instead of being re-read
# per distinct cut date. The bound only trims runs OLDER than every window that uses it: the caller still
# cuts the list at its own `since`, and the "list reached CANARY_INGRESS_RUN_LIMIT" fail-closed guard
# is unchanged (a bounded list that hits the cap is judged exactly like an unbounded one).
_ingress_horizon() {
  _horizon_from "$1" "${CANARY_INGRESS_HORIZON_TIERS-8 15}"
  _INGRESS_FROM="$_HORIZON_FROM"
}

# _horizon_from <since_z> <tiers> — the tier logic behind _ingress_horizon, sets _HORIZON_FROM (also used for the
# per-role run lists, _agent_run_json, #1259 option B).
_horizon_from() {
  local since="$1" tiers="$2" s now days t
  _HORIZON_FROM=""
  [ -n "$since" ] || return 0
  s="$(_epoch "$since")"
  case "$s" in ''|*[!0-9]*|0) return 0 ;; esac
  printf -v now '%(%s)T' -1
  # Whole days back, rounded UP (a partial day counts). The horizon DATE is the start (00:00Z) of the day
  # t days ago, which is never later than the instant t days ago, so t >= days is enough to cover <since>.
  days=$(( (now - s + 86399) / 86400 ))
  [ "$days" -ge 1 ] || days=1
  for t in $tiers; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    if [ "$days" -le "$t" ]; then
      _HORIZON_FROM="$(date -u -d "-${t} days" +%Y-%m-%d 2>/dev/null || date -u -v"-${t}d" +%Y-%m-%d 2>/dev/null || true)"
      return 0
    fi
  done
  return 0
}

# _ingress_runs_fetch <repo> <ingress_workflow> <since_z> — the ingress run list for one window: the
# date-bounded list (_ingress_horizon) when that is provably complete for the window, else the unbounded
# one. GitHub caps ANY workflow-run listing that uses a search parameter (`created`) at 1,000 results, so a
# bounded response of 1,000 runs may have lost the older end silently, and CANARY_INGRESS_RUN_LIMIT's own
# cap guard (default 5000) would not notice. A bounded list that reaches 1,000 is therefore trusted only if
# it reaches back BEFORE the window start (everything newer than its oldest run is then in it); otherwise
# the unbounded list is read instead (slower, but exactly the pre-bound behavior). Same exit codes as
# _repo_wf_runs_cached (3 = the workflow does not exist).
_INGRESS_BOUNDED_MAX=1000
_ingress_runs_fetch() {
  local repo="$1" iwf="$2" since="$3" out rc=0 n oldest
  _ingress_run_limit; _ingress_horizon "$since"
  out="$(_repo_wf_runs_cached "$repo" "$iwf" 1 "$_INGRESS_RUN_LIMIT" "$_INGRESS_FROM")" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$_INGRESS_FROM" ]; then
    n="$(jq 'if type == "array" then length else 0 end' <<< "${out:-[]}" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -ge "$_INGRESS_BOUNDED_MAX" ]; then
      oldest="$(jq -r '[.[]? | (.createdAt // "")] | min // ""' <<< "$out" 2>/dev/null || true)"
      if [ -z "$since" ] || [ -z "$oldest" ] || ! [[ "$oldest" < "$since" ]]; then
        out="$(_repo_wf_runs_cached "$repo" "$iwf" 1 "$_INGRESS_RUN_LIMIT" "")" || rc=$?
      fi
    fi
  fi
  printf '%s\n' "$out"
  return "$rc"
}

# _ingress_run_limit — CANARY_INGRESS_RUN_LIMIT (the `gh run list -L` for an ingress), normalized once so
# the value sent to the API and the cap comparison in _ingress_agent_runs can never disagree (a
# non-numeric or < 1 value falls back to the 5000 default instead of aborting the fetch).
_ingress_run_limit() {
  local n="${CANARY_INGRESS_RUN_LIMIT:-5000}"
  case "$n" in ''|*[!0-9]*) n=5000 ;; esac
  [ "$n" -lt 1 ] && n=5000
  _INGRESS_RUN_LIMIT="$n"   # a variable, not stdout: callers avoid a `$(...)` fork per call (#1259)
}

# _ingress_agent_runs <agent> <repo> <role> <since_z>   (ingress runs JSON on stdin)
# — the agent's runs on a collapsed repo, one record per completed ingress run in which the
# <role> job ran: {conclusion, createdAt, databaseId, workflowName: <run_workflow>, role}.
# workflowName is the agent's registered run_workflow so its benign/suspect classes keep
# matching across the collapse (parity with the legacy per-role bucket). Only runs at/after
# <since_z> have their jobs read. A run with no jobs (unless it is a startup_failure, which hit
# every role) or unreadable jobs makes the member UNRESOLVED.
_ingress_agent_runs() {
  local agent="$1" repo="$2" role="$3" since="$4" wf iraw id created rconc jobs rec recs=""
  _reg_run_workflow "$agent"; wf="$_REG_VAL"
  iraw="$(cat)"
  # Bound the per-run `gh run view` fan-out (#810/#819): read at most CANARY_INGRESS_JOBS_MAX
  # (default 300) of the newest in-window runs. Beyond that the member is UNRESOLVED (fail closed) —
  # EXCEPT for the trailing BASELINE read (_baseline_daily arms _CANARY_INGRESS_TRUNC_FLAG): the
  # baseline only sizes the sample target, so a truncated read is a valid sample of the NEWEST days.
  # The first unread run's day is recorded and _baseline_daily drops that (incomplete) day and every
  # older one, rather than blocking a busy collapsed repo forever. Gating windows stay strict.
  local jobs_max="${CANARY_INGRESS_JOBS_MAX:-300}" nread=0 jrc role_oldest="" skipkind norole_created="" ncr
  case "$jobs_max" in ''|*[!0-9]*) jobs_max=300 ;; esac
  [ "$jobs_max" -lt 1 ] && jobs_max=300
  # The RUN LIST itself is capped too (`gh run list -L CANARY_INGRESS_RUN_LIMIT`, default 5000). A list
  # that hit its cap AND does not reach back past the window start may be missing older in-window runs,
  # so a very busy ingress would look quieter than it is (#1244 item 11). Fail closed exactly like the
  # jobs cap: the BASELINE read records the oldest listed day (a valid sample of the newest days), a
  # gating window is UNRESOLVED. A list that reaches back before the window start is complete.
  local list_max list_n list_oldest
  _ingress_run_limit; list_max="$_INGRESS_RUN_LIMIT"
  # `gh run list` output is passed through unchecked on success: a non-array body would count as 0 runs
  # (skipping the cap check) and iterate to nothing, reading as "no caller". Fail closed instead.
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "${iraw:-[]}"; then
    _record_unresolved "$agent" "$repo" "the ingress run list is not a JSON array"
    iraw='[]'; list_n=0
  else
    list_n="$(jq 'length' <<< "${iraw:-[]}" 2>/dev/null || echo 0)"
  fi
  if [ "${list_n:-0}" -ge "$list_max" ]; then
    list_oldest="$(jq -r '[.[]? | (.createdAt // "")] | min // ""' <<< "$iraw" 2>/dev/null || true)"
    if [ -z "$since" ] || [ -z "$list_oldest" ] || ! [[ "$list_oldest" < "$since" ]]; then
      if [ -n "$list_oldest" ] && [ -n "${_CANARY_INGRESS_TRUNC_FLAG:-}" ] && printf '%s\n' "${list_oldest:0:10}" >> "$_CANARY_INGRESS_TRUNC_FLAG" 2>/dev/null; then
        echo "::warning::$agent $repo: the ingress run list reached CANARY_INGRESS_RUN_LIMIT ($list_max) in the baseline window; using the newest days only." >&2
      else
        _record_unresolved "$agent" "$repo" "the ingress run list reached CANARY_INGRESS_RUN_LIMIT ($list_max) before the window start; older in-window runs may be missing (raise CANARY_INGRESS_RUN_LIMIT if this repo legitimately has that many runs)"
      fi
    fi
  fi
  while IFS=$'\t' read -r id created rconc; do
    [ -z "$id" ] && continue
    [ "$created" = "-" ] && created=""   # "-" kept the empty field from collapsing in the tab-split read
    if [ "$nread" -ge "$jobs_max" ]; then
      if [ -n "${_CANARY_INGRESS_TRUNC_FLAG:-}" ] && printf '%s\n' "${created:0:10}" >> "$_CANARY_INGRESS_TRUNC_FLAG" 2>/dev/null; then
        echo "::warning::$agent $repo: more than $jobs_max ingress runs in the baseline window; using the newest days only (CANARY_INGRESS_JOBS_MAX)." >&2
      else
        _record_unresolved "$agent" "$repo" "more than $jobs_max ingress runs in the window; job reads capped (CANARY_INGRESS_JOBS_MAX)"
      fi
      break
    fi
    nread=$((nread + 1))
    jrc=0; jobs="$(_run_jobs_json "$repo" "$id")" || jrc=$?
    if [ "$jrc" -eq 1 ]; then
      # Circuit breaker: the jobs endpoint stayed unreadable after the full backoff, so every later
      # run would burn the same ~30s+ of retries (300 runs can outlive the job timeout before
      # sync-issues records the fail-closed state). Stop reading; the member is UNRESOLVED.
      _record_unresolved "$agent" "$repo" "jobs endpoint unreadable (run $id) — stopped reading jobs for this member"; break
    elif [ "$jrc" -ne 0 ]; then
      _record_unresolved "$agent" "$repo" "jobs of ingress run $id are unreadable"; continue
    fi
    rec="$(jq -c --arg role "$role" --arg wf "$wf" --arg id "$id" --arg created "$created" --arg rconc "$rconc" '
      def rank(c):
        # failure/timed_out rank STRICTLY above action_required/startup_failure: max_by keeps the last of
        # tied elements, so a failed job followed by an action_required one must not reduce the role to
        # action_required (downstream counters select conclusion=="failure" and would drop the failure).
        if   c == "failure" or c == "timed_out" then 7
        elif c == "action_required" or c == "startup_failure" then 6
        elif c == "cancelled" then 5   # an interrupted job must not be masked by a green sibling
        elif c == "success"   then 4
        elif c == null or c == "skipped" then 0
        else 2 end;
      (.jobs // []) as $jobs
      | if ($jobs | length) == 0 then
          # A run cancelled before any job started (e.g. superseded by workflow concurrency) never
          # executed this role: it is not a success or a failure, so it is simply not a record. A run
          # whose jobs are merely not recorded YET (jobs-API lag) looks the same for a moment; that is
          # the same tolerance the gate already has for an in-flight run (conclusion null, ignored), the
          # jobs are re-read on every sweep (never persisted across ticks), so the run is attributed
          # properly on the next tick. Holding the gate for it would false-block on every
          # concurrency-superseded run (#1244 item 12: accepted, pinned by a test).
          (if $rconc == "startup_failure" then {conclusion: "startup_failure", nojobs: true}
           elif $rconc == "cancelled" then {skipped: "cancelled"}
           else "UNATTRIBUTED" end)
        else
          ([ $jobs[] | select(((.name // "") | split(" / ")[0]) == $role) | {c: .conclusion, r: rank(.conclusion)} ]) as $rj
          # No job carries the role: either the role was added to the ingress AFTER this run
          # (pre-adoption — benign) or ingress_job is renamed/misspelled (blind). The caller decides,
          # once it knows whether ANY run in the window carries the role.
          | if ($rj | length) == 0 then "NOROLE"
          else ($rj | max_by(.r)) as $w
          | if $w.r == 0 then {skipped: "role"}
            # A job-level timeout surfaces as a failed run on a legacy per-role workflow.
            else {conclusion: (if $w.c == "timed_out" then "failure" else $w.c end)} end
          end
        end
      | if . == "UNATTRIBUTED" or . == "NOROLE" or (type == "object" and has("skipped")) then .
        else . + {createdAt: $created, databaseId: ($id | tonumber), workflowName: $wf, role: $role} end
    ' <<< "$jobs" 2>/dev/null)" || rec='"UNATTRIBUTED"'
    if [ "$rec" = '"UNATTRIBUTED"' ]; then
      _record_unresolved "$agent" "$repo" "ingress run $id has no attributable jobs"; continue
    fi
    if [ "$rec" = '"NOROLE"' ]; then
      # Defer: pre-adoption runs are benign, a renamed ingress_job is not (see after the loop).
      # Keep the run's own createdAt (no payload re-parse later); "-" stands in for a missing one so
      # word-splitting cannot drop it — a run with an unknown date must still count as blind.
      norole_created+="${created:--} "; continue
    fi
    skipkind="$(jq -r 'if type == "object" then (.skipped // empty) else empty end' <<< "$rec" 2>/dev/null || true)"
    if [ -n "$skipkind" ]; then
      [ "$skipkind" = "role" ] && role_oldest="$created"   # the role job ran (skipped): it exists here
      continue
    fi
    # newest→oldest: the last assignment is the OLDEST run carrying the role. A job-less startup_failure
    # (nojobs) carries NO role job, so it must not count as the role's appearance.
    [ "$(jq -r '.nojobs // empty' <<< "$rec" 2>/dev/null || true)" = "true" ] || role_oldest="$created"
    [ -n "$rec" ] && recs+="$(jq -c 'del(.nojobs)' <<< "$rec")"$'\n'
  done < <(jq -r --arg since "$since" \
    '[ .[]? | select(.conclusion != null and .conclusion != "")
          | select($since == "" or (.createdAt // "") >= $since) ]
          | sort_by(.createdAt // "") | reverse | .[]
          | [(.databaseId|tostring), (if (.createdAt // "") == "" then "-" else .createdAt end), .conclusion] | @tsv' 2>/dev/null <<< "${iraw:-[]}")
  # Runs where no job carried the role. If the role appears in an OLDER run, a no-role run that is
  # older still predates the role's adoption by the ingress and is benign; one NEWER than the role's
  # oldest appearance, or any when no run in the window carries the role at all (renamed/misspelled
  # ingress_job), cannot be attributed → UNRESOLVED. The member stays blocked only for that.
  if [ -n "$norole_created" ]; then
    local blind=0
    for ncr in $norole_created; do
      if [ -z "$role_oldest" ] || [ "$ncr" = "-" ] || ! [[ "$ncr" < "$role_oldest" ]]; then blind=$((blind + 1)); fi
    done
    [ "$blind" -gt 0 ] && _record_unresolved "$agent" "$repo" "$blind ingress run(s) carry no '$role' job and are not older than the role's first appearance (ingress_job renamed or misspelled?)"
  fi
  printf '%s' "$recs" | jq -cs '.'
}

# _agent_run_json <agent> <repo> <since_z> — the agent's runs on one ring member since the given
# Zulu timestamp (same record shape as _run_json, plus `role` for ingress-attributed runs).
# Resolution order (#1224):
#   1. the per-role workflow (`run_workflow`) exists → its runs (legacy, unchanged);
#   2. it is absent but the ingress exists and the agent registers `ingress_job` → the ingress
#      runs in which that role job ran;
#   3. neither exists → [] (the repo does not consume this agent, #747);
#   4. the ingress exists but the role cannot be attributed (no `ingress_job`, a job-less run,
#      unreadable jobs) → the member is UNRESOLVED (see _record_unresolved), never silent.
# A genuine fetch failure fails CLOSED (non-zero), exactly like _run_json.
_agent_run_json() {
  local agent="$1" repo="$2" since="$3" wf iwf raw iraw role rc=0
  [ -n "${_TIMING_CALLS:-}" ] && { printf . >> "$_TIMING_CALLS" 2>/dev/null || true; }   # call counter (CANARY_TIMING)
  if [ -z "$repo" ] || [ "$repo" = '*' ]; then echo '[]'; return 0; fi
  _reg_run_workflow "$agent"; wf="$_REG_VAL"
  # Date-bound the per-role list (#1259, option B): every window the gate samples starts at most ~2 weeks back, so the
  # newest 1000 runs of a busy workflow are mostly older than anything read. One fixed tier (CANARY_RUNS_HORIZON_TIERS,
  # days, default "15"; EMPTY disables the bound) so every window shares ONE fetch per (repo, workflow). No fallback
  # read is needed when the bounded list hits the 1000 cap: GitHub returns newest-first, so it is then exactly the
  # newest-1000 the unbounded call returns (the existing truncation behavior, unchanged). A window older than the tier
  # (a long soak) gets the unbounded list as before.
  _horizon_from "$since" "${CANARY_RUNS_HORIZON_TIERS-15}"
  raw="$(_repo_wf_runs_cached "$repo" "$wf" 1 1000 "$_HORIZON_FROM")" || rc=$?
  if [ "$rc" -eq 3 ]; then
    rc=0; _reg_ingress_wf; iwf="$_REG_VAL"
    iraw="$(_ingress_runs_fetch "$repo" "$iwf" "$since")" || rc=$?
    case "$rc" in
      0)
        _reg_ingress_job "$agent"; role="$_REG_VAL"
        if [ -z "$role" ]; then
          _record_unresolved "$agent" "$repo" "no '$wf' workflow but '$iwf' is present and the agent registers no ingress_job"
          echo '[]'; return 0
        fi
        _ingress_agent_runs "$agent" "$repo" "$role" "$since" <<< "$iraw"; return 0 ;;
      3) echo '[]'; return 0 ;;
      *) return 1 ;;
    esac
  elif [ "$rc" -ne 0 ]; then
    return 1
  fi
  jq -c --arg since "$since" \
    '[ .[]? | select($since == "" or (.createdAt // "") >= $since) ]' \
    <<< "${raw:-[]}" 2>/dev/null || echo '[]'
}

# _tier_sample <agent> <since_z> <repo...> — EXECUTED runs (success+failure) on the
# source tier since the candidate cut. Prints "<executed> <earliest_createdAt|->".
_tier_sample() {
  local agent="$1" since="$2"; shift 2
  local repo json executed=0 earliest="" e
  for repo in "$@"; do
    json="$(_agent_run_json "$agent" "$repo" "$since")"
    executed=$(( executed + $(jq '[.[]?|select(.conclusion=="success" or .conclusion=="failure")]|length' 2>/dev/null <<< "${json:-[]}" || echo 0) ))
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
  local repo json rid rwf rrole sig sig_rc matched=0 executed=0 incomplete=0 count
  local exec_filter='.[]?|select(.conclusion=="success" or .conclusion=="failure")'
  local fail_filter='.[]?|select(.conclusion=="failure")'
  if [ "$before" != "-" ]; then
    exec_filter="$exec_filter|select(.createdAt < \"$before\")"
    fail_filter="$fail_filter|select(.createdAt < \"$before\")"
  fi
  for repo in "$@"; do
    { [ -z "$repo" ] || [ "$repo" = '*' ]; } && continue
    json="$(_agent_run_json "$agent" "$repo" "$since")"
    count="$(jq "[${exec_filter}]|length" 2>/dev/null <<< "$json" || echo 0)"
    executed=$(( executed + ${count:-0} ))
    while IFS=$'\t' read -r rid rwf rrole || [ -n "$rid" ]; do
      rid="${rid%$'\r'}"
      rwf="${rwf%$'\r'}"
      rrole="${rrole%$'\r'}"
      [ -z "$rid" ] && continue
      sig_rc=0
      sig="$(_run_signature "$repo" "$rid" "$rrole")" || sig_rc=$?  # || prevents set -e on lookup failure
      if [ -z "$sig" ]; then
        [ "$sig_rc" -ne 0 ] && incomplete=$(( incomplete + 1 ))  # lookup failed; genuine empty sig is fine
        continue
      fi
      if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then
        matched=$(( matched + 1 ))
      fi
    done < <(jq -r "[${fail_filter}]|.[]|[(.databaseId // \"\"|tostring),(.workflowName // \"\"),(.role // \"\")]|@tsv" 2>/dev/null <<< "$json")
  done
  echo "$matched $executed $incomplete"
}

# Memoization cache for _run_signature: keyed by "repo:run_id:role".
# Avoids duplicate gh run view calls for the same (repo, run_id) across agents
# in evaluate-all (where multiple agents can share repos).
declare -A _RUN_SIG_CACHE=()

# _run_signature <repo> <run_id> [<role>] — the failed step names of a run, joined by newlines
# (the "step/error signature" the allowlist matches against). A <role> (an ADR-0007 ingress-
# attributed run, #1224) scopes it to that role's own jobs, so another role's failure in the
# same ingress run can never make this agent's failure look benign (or suspect). Empty repo/wildcard/id or
# any gh error → "" with exit 1 (fail-closed: an unknown signature is never treated as
# benign, and callers that need to distinguish a lookup failure from a genuine empty
# signature check the exit code). A successful lookup with no failed steps → "" exit 0.
# The $'\x01' sentinel in the cache marks a prior lookup failure so it is not retried.
_run_signature() {
  local repo="$1" id="$2" role="${3:-}" cache_key sig json
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}:${role}"
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
  json="$(_run_jobs_json "$repo" "$id" 1)" || {
    _RUN_SIG_CACHE["$cache_key"]=$'\x01'
    echo ""; return 1
  }
  sig="$(jq -r --arg role "$role" '[.jobs[]?|select($role == "" or ((.name // "")|split(" / ")[0]) == $role)
    |.steps[]?|select(.conclusion=="failure")|.name] | join("\n")' 2>/dev/null <<< "$json" || echo "")"
  _RUN_SIG_CACHE["$cache_key"]="$sig"
  echo "$sig"
}

# _failure_benign <repo> <run_id> <workflow_name> <patterns_tsv> [<role>] — return 0 if this
# in-window failure matches any allowlist entry, else 1. Fail-closed on an empty signature.
_failure_benign() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" role="${5:-}" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid" "$role")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re; do
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# _failure_suspect <repo> <run_id> <workflow_name> <patterns_tsv> [<role>] — return 0 if this
# in-window failure matches any SUSPECT allowlist entry (#668 increment 2), else 1. Reuses
# the benign_match pure matcher against the run's failed-step signature; fail-closed on an
# empty signature (an unknown signature is never treated as suspect). A suspect match does
# NOT exclude the failure — it narrows the triage verdict (SUSPECT vs REGRESSION) only.
_failure_suspect() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" role="${5:-}" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid" "$role")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re || [ -n "$wf_re" ]; do
    wf_re="${wf_re%$'\r'}"
    step_re="${step_re%$'\r'}"
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# Memoization for _run_reusable_sha. Callers run it in command substitutions (subshells), so the
# in-memory map alone is lost between the health pass and the blocker-evidence pass; when the
# sweep has a _RUNS_CACHE_DIR the result is also persisted there so each run's log is fetched once.
declare -A _RUN_SHA_CACHE=()

# _run_reusable_sha <agent> <repo> <run_id> — every distinct commit SHA the run's calls to THIS
# agent's reusable resolved to (one per line), read from the "Uses: <host>/<reusable>@<ref> (<sha>)"
# lines GitHub prints in the run log (#1176). Only lines naming the registry host + full reusable
# path count, so a different workflow with a similar filename is never attributed. Empty (exit 1)
# when the log is unreadable or has no such line; an unknown SHA is never attributed to an older
# release (fail closed — see _run_is_stale). Lookup failures are cached as empty too.
_run_reusable_sha() {
  local agent="$1" repo="$2" id="$3" key="$1:$2:$3" reusable host cachef="" keyhash log shas="" line
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 1; }
  if [[ -v _RUN_SHA_CACHE["$key"] ]]; then
    shas="${_RUN_SHA_CACHE[$key]}"; [ -n "$shas" ] && printf '%s\n' "$shas"; [ -n "$shas" ]; return
  fi
  if [ -n "${_RUNS_CACHE_DIR:-}" ] && [ -d "$_RUNS_CACHE_DIR" ]; then
    # Hash the key into the filename (as _repo_wf_runs_cached does): char-substitution would map
    # distinct (agent, repo, run) keys to one file and could hand one run another run's SHA.
    keyhash="$(printf '%s' "$key" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -d' ' -f1)"
    [ -n "$keyhash" ] || keyhash="${key//[^A-Za-z0-9._-]/_}"
    cachef="$_RUNS_CACHE_DIR/sha_${keyhash}"
    if [ -f "$cachef" ]; then
      shas="$(<"$cachef")"; _RUN_SHA_CACHE["$key"]="$shas"
      [ -n "$shas" ] && printf '%s\n' "$shas"; [ -n "$shas" ]; return
    fi
  fi
  reusable="$(_agent_field "$agent" reusable)"
  host="$(_agent_field "$agent" host)"; host="${host:-$THIS_REPO}"
  log="$(gh run view "$id" --repo "$repo" --log 2>/dev/null)" || log=""
  if [ -n "$reusable" ]; then
    # `gh run view --log` lines are "<job>\t<step>\t<timestamp> <text>". GitHub prints the genuine
    # "Uses:" line while setting a job up, before any of that job's own output, so only the FIRST
    # "Uses:" line per job is trusted: a later line a job merely echoes (a forged old SHA) is ignored.
    # The step column is NOT used — real logs often show it as "UNKNOWN STEP" (verified).
    local -A seen_job=()
    local jobcol text
    while IFS=$'\t' read -r jobcol _ text; do
      [[ "$text" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z\ (Uses:\ .*)$ ]] || continue
      line="${BASH_REMATCH[1]}"
      [[ -v seen_job["$jobcol"] ]] && continue
      seen_job["$jobcol"]=1
      [[ "$line" == "Uses: $host/$reusable@"* ]] || continue
      [[ "$line" =~ \(([0-9a-f]{7,40})\)$ ]] && shas+="${BASH_REMATCH[1]}"$'\n'
    done <<< "$log"
    shas="$(printf '%s' "$shas" | sort -u)"
  fi
  _RUN_SHA_CACHE["$key"]="$shas"
  [ -n "$cachef" ] && printf '%s' "$shas" > "$cachef" 2>/dev/null || true
  [ -n "$shas" ] && printf '%s\n' "$shas"; [ -n "$shas" ]
}

# _run_is_stale <agent> <cand> <repo> <run_id> — 0 only when the run PROVABLY executed a release
# other than the candidate (#1176): a ring's members run the previous release until promoted, so
# their failures say nothing about the candidate. Anything undeterminable (no cand, no Uses: line)
# or ambiguous (a run that called the reusable at several SHAs, any of them the candidate) is NOT
# stale, so it still counts and blocks — the gate never gets more permissive on a guess.
_run_is_stale() {
  local agent="$1" cand="$2" repo="$3" id="$4" sha shas
  { [ -z "$cand" ] || [ "$cand" = "-" ]; } && return 1
  shas="$(_run_reusable_sha "$agent" "$repo" "$id")" || return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    case "$cand" in "$sha"*) return 1 ;; esac
    case "$sha" in "$cand"*) return 1 ;; esac
  done <<< "$shas"
  return 0
}

# _cumulative_health <agent> <since_z> <differs 0|1> <cand|-> <repo...> — failures +
# startup_failures across EVERY given tier repo since the candidate cut. Only runs that executed
# the candidate count (#1176): a failure from a run provably on an OLDER release (see
# _run_is_stale) is tallied separately as target-ring health and never blocks. cand "-" disables
# that attribution (every failure counts, the pre-#1176 behaviour). Failures
# matching the per-reusable known-benign allowlist (#1025 P2) are counted separately and
# excluded from the blocking total; which allowlist entries apply depends on whether the
# candidate changed the reusable (differs — see _benign_patterns, #668). A counted (non-
# benign) failure that matches a `suspect_failure_classes` entry sets the suspect flag
# (#668 increment 2) — it still counts toward the blocking total (SUSPECT blocks like
# REGRESSION), but downstream triage renders SUSPECT + guidance instead of a bare
# REGRESSION. Prints "<failures> <startup_failures> <benign_excluded> <suspect_count> <old_release_failures>".
_cumulative_health() {
  local agent="$1" since="$2" differs="$3" cand="${4:--}"; shift 4
  local repo json fail=0 startup=0 benign=0 suspect=0 stale=0 patterns="" suspect_patterns="" rid rwf rrole
  patterns="$(_benign_patterns "$agent" "$differs")"
  suspect_patterns="$(_suspect_patterns "$agent")"
  for repo in "$@"; do
    json="$(_agent_run_json "$agent" "$repo" "$since")"
    # startup_failure runs never executed a job, so no release can be attributed to them (no
    # "Uses:" log line): they always count, fail closed (#1176).
    startup=$(( startup + $(jq '[.[]?|select(.conclusion=="startup_failure")]|length' 2>/dev/null <<< "${json:-[]}" || echo 0) ))
    if [ -z "$patterns" ] && [ -z "$suspect_patterns" ] && [ "$cand" = "-" ]; then
      # No benign/suspect patterns and no candidate attribution — count all failures with one
      # jq pass, avoiding a gh run view call per failure.
      fail=$(( fail + $(jq '[.[]?|select(.conclusion=="failure")]|length' 2>/dev/null <<< "${json:-[]}" || echo 0) ))
    else
      while IFS=$'\t' read -r rid rwf rrole; do
        if _run_is_stale "$agent" "$cand" "$repo" "$rid"; then
          stale=$(( stale + 1 ))
        elif [ -n "$patterns" ] && _failure_benign "$repo" "$rid" "$rwf" "$patterns" "$rrole"; then
          benign=$(( benign + 1 ))
        else
          fail=$(( fail + 1 ))
          if [ -n "$suspect_patterns" ] && _failure_suspect "$repo" "$rid" "$rwf" "$suspect_patterns" "$rrole"; then
            suspect=$(( suspect + 1 ))
          fi
        fi
      done < <(jq -r '.[]?|select(.conclusion=="failure")|[(.databaseId // "" | tostring),(.workflowName // ""),(.role // "")]|@tsv' 2>/dev/null <<< "$json")
    fi
  done
  echo "$fail $startup $benign $suspect $stale"
}

# _baseline_daily <agent> <window_days> <repo...> — per-day EXECUTED counts on the
# source tier over the trailing window_days (window_days integers, zero-filled — fewer only when a
# capped collapsed-repo read left the older days unknown, see _ingress_agent_runs),
# feeding the robust spike-capped baseline for the sample target (#548).
_baseline_daily() {
  local agent="$1" window="$2"; shift 2
  local since repo json day i count out="" tflag d cutday any_trunc=0 total=0
  local -A dsum=() dknown=() rcount=()
  local -a days=()
  since="$(_iso_now_minus_days "$window")"
  for (( i=0; i<window; i++ )); do
    day="$(date -u -d "-${i} days" +%Y-%m-%d 2>/dev/null || date -u -v"-${i}d" +%Y-%m-%d 2>/dev/null || echo "")"
    days+=("$day")
  done
  # A capped ingress read (see _ingress_agent_runs) leaves every day OLDER than that repo's first unread
  # run's day unknown — NOT zero — and that boundary day itself only partly counted. Truncation is
  # tracked PER REPO: a truncated member drops only its own older days, so a fully-read member's history
  # still counts. The boundary day is kept only when it has observed runs (a lower bound, never a false
  # zero). A day is dropped from the baseline only when NO member knows it. A truncated read must also
  # never look like "no caller" (an all-zero baseline lets waive_sample_if_no_caller skip sampling in
  # _pair_state), so if nothing countable was observed the baseline is a non-zero floor, which sizes the
  # sample target at its clamp minimum.
  for repo in "$@"; do
    tflag="$(mktemp 2>/dev/null || true)"   # unwritable → the ingress cap stays strict (UNRESOLVED)
    json="$(_CANARY_INGRESS_TRUNC_FLAG="$tflag" _agent_run_json "$agent" "$repo" "$since")"
    cutday=""
    if [ -n "$tflag" ] && [ -s "$tflag" ]; then
      while IFS= read -r d; do [ -n "$d" ] && { [ -z "$cutday" ] || [[ "$d" > "$cutday" ]]; } && cutday="$d"; done < "$tflag"
    fi
    [ -n "$tflag" ] && rm -f "$tflag"
    [ -n "$cutday" ] && any_trunc=1
    rcount=()
    while IFS= read -r d; do [ -n "$d" ] && rcount["$d"]=$(( ${rcount["$d"]:-0} + 1 )); done \
      < <(jq -r '.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt[0:10]?' 2>/dev/null <<< "$json" || true)
    for day in "${days[@]}"; do
      count="${rcount["$day"]:-0}"
      if [ -n "$cutday" ]; then
        [[ "$day" < "$cutday" ]] && continue
        [ "$day" = "$cutday" ] && [ "$count" -eq 0 ] && continue
      fi
      dknown["$day"]=1
      dsum["$day"]=$(( ${dsum["$day"]:-0} + count ))
    done
  done
  for day in "${days[@]}"; do
    # No truncated member → every day is known (zero-filled); otherwise only days some member knows.
    if [ "$any_trunc" -eq 1 ] && [ "$#" -gt 0 ] && [ -z "${dknown["$day"]:-}" ]; then continue; fi
    count="${dsum["$day"]:-0}"
    total=$(( total + count ))
    out+="${count} "
  done
  [ "$any_trunc" -eq 1 ] && [ "$total" -eq 0 ] && out="1 "
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

# _run_decision_class <repo> <run_id> <prefix> [<role>] [<agent>] — the decision class a run took
# (the taken `<prefix><class>` no-op step; skipped branches ignored), via `gh run view --json jobs`. A
# <role> (an ADR-0007 ingress-attributed run, #1224) scopes the read to that role's own jobs.
# Empty (status 0) on a missing repo/id, a run with no decision step, or a run that is permanently gone
# (deleted/expired, HTTP 404 — an expected outcome that simply contributes nothing to the tally).
# A TRANSIENT jobs-read failure (the endpoint stayed unreadable) is NOT "no decision step": it is
# recorded UNRESOLVED for <agent>'s member (the gate holds, #1244 item 3), echoes empty, returns 1 so
# the sampler stops reading that member, and is never memoized (the next tick retries).
_run_decision_class() {
  local repo="$1" id="$2" prefix="$3" role="${4:-}" agent="${5:-}" cache_key json cls jrc=0
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}:${role}"
  if [[ -v _RUN_DECISION_CACHE["$cache_key"] ]]; then
    echo "${_RUN_DECISION_CACHE[$cache_key]}"; return 0
  fi
  json="$(_run_jobs_json "$repo" "$id" 1 2>/dev/null)" || jrc=$?
  case "$jrc" in
    0) ;;
    2) json='{}' ;;   # permanently gone: contributes nothing
    *)
      _record_unresolved "$agent" "$repo" "jobs of run $id are unreadable while sampling the decision mix (correctness evidence missing)"
      echo ""; return 1 ;;
  esac
  if [ -n "$role" ]; then
    json="$(jq -c --arg role "$role" 'if has("jobs") then .jobs |= map(select(((.name // "")|split(" / ")[0]) == $role)) else error("Missing jobs key") end' <<< "$json" 2>/dev/null || echo '{}')"
  fi
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
  local repo json rid rrole cls sampled=0
  declare -A counts=()
  local filter='.[]?|select(.conclusion=="success" or .conclusion=="failure")'
  [ "$before" != "-" ] && filter="$filter|select(.createdAt < \"$before\")"
  for repo in "$@"; do
    [ "$sampled" -ge "$max_k" ] && break
    { [ -z "$repo" ] || [ "$repo" = '*' ]; } && continue
    json="$(_agent_run_json "$agent" "$repo" "$since")"
    while IFS=$'\t' read -r rid rrole; do
      [ -z "$rid" ] && continue
      [ "$sampled" -ge "$max_k" ] && break
      # A transient jobs-read failure (status 1) is recorded UNRESOLVED by _run_decision_class; stop
      # reading this member rather than burn one failing call per remaining run.
      cls="$(_run_decision_class "$repo" "$rid" "$prefix" "$rrole" "$agent")" || break
      [ -z "$cls" ] && continue
      counts["$cls"]=$(( ${counts["$cls"]:-0} + 1 ))
      sampled=$(( sampled + 1 ))
    done < <(jq -r "[${filter}]|sort_by(.createdAt)|reverse|.[]|[(.databaseId|tostring),(.role // \"\")]|@tsv" 2>/dev/null <<< "$json")
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
  local agent="$1" cand="$2" pair_transition="${3:-}"
  local knobs; knobs="$(_jq -c --arg a "$agent" '.agents[$a].gate.correctness // ""')"
  [ -z "$knobs" ] || [ "$knobs" = '""' ] && return 0
  local chans frontier="" ch c
  chans="$(ordered_channels "$agent")"
  local transition source cut_z prefix
  if [ -n "$pair_transition" ]; then
    # The blocked pair is known (#1118): use ITS source tier, not one re-derived on the assumption
    # that the candidate always sits on `next`.
    transition="$pair_transition"
  else
    local chan_array=(); IFS=, read -r -a chan_array <<< "$chans"
    for ch in "${chan_array[@]}"; do
      c="$(channel_commit "$agent" "$ch")"
      if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
    done
    [ -z "$frontier" ] && return 0
    transition="$(transition_key "$frontier" "$chans")"
  fi
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

# _pair_state <agent> <source> <frontier> <cand> <transition> — evaluate the graduated gate for
# ONE ring transition (#1118). The candidate is the commit CURRENTLY ON <source> (not always
# `next`); the gate measures dwell from THAT candidate's own cut, samples on the <source> tier,
# and scopes cumulative health to every tier EXCEPT a ring strictly BELOW <source> that runs a
# DIFFERENT (newer) candidate — so a newer candidate churning on a lower tier can never block an
# older, independently-clean candidate on a higher pair. A ring member whose runs cannot be
# attributed (#1224) holds an otherwise-clean gate BLOCKED with triage UNRESOLVED. Echoes the same 18-field line documented
# on _frontier_state. triage/mix_shift/downgrade semantics are unchanged from the single-frontier
# implementation this was extracted from.
_pair_state() {
  local agent="$1" source="$2" frontier="$3" cand="$4" transition="$5" chans="$6" commits_csv="$7"
  local cut_z now_epoch
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  if [ -z "$cut_z" ]; then
    # Cannot determine the per-candidate window start — fail closed to prevent unbounded history queries.
    echo "${cand:--} $frontier $transition BLOCKED 0 0 0 0 0 0 0 - - - 0 0 0 0"; return 0
  fi
  now_epoch="$(date -u +%s)"

  # Arm the UNRESOLVED-member flag (#1224): _agent_run_json records each ring member whose runs
  # cannot be attributed (ADR-0007 ingress present, role job unresolvable). A file, because the
  # run reads below happen in subshells. A caller may pre-arm it (sync-issues evidence).
  local uflag="${_CANARY_UNRESOLVED_FLAG:-}" uflag_owned=0
  if [ -z "$uflag" ]; then
    # Per-process path (never shared across concurrent invocations) so _unresolved_evidence in
    # this same process can reuse the flag instead of re-walking the runs (#1224).
    uflag="$(_unresolved_flag_path "$agent" "$cand")"; uflag_owned=1
    if : >"$uflag" 2>/dev/null; then
      export _CANARY_UNRESOLVED_FLAG="$uflag"
    else
      # Cannot arm the flag (TMPDIR unwritable/full) → unattributable members could not be
      # recorded; fail closed rather than let a clean-looking gate PROMOTE.
      echo "WARN: cannot create unresolved-member flag '$uflag'; failing closed" >&2
      echo "${cand:--} $frontier $transition BLOCKED 0 0 0 0 0 0 0 FLAG_ERROR - - 0 0 0 0"; return 0
    fi
  fi

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
  # chans / commits_csv are the ring order and each ring's commit ("-" = unresolvable), resolved ONCE
  # by _frontier_state: channel_commit runs in a subshell, so its own cache is lost between calls and
  # every lookup would be another API round-trip.
  local chan_array=() commit_array=() idx src_idx=-1 dst_idx=-1
  IFS=, read -r -a chan_array <<< "$chans"
  IFS=, read -r -a commit_array <<< "$commits_csv"
  for idx in "${!chan_array[@]}"; do
    [ "${chan_array[$idx]}" = "$source" ] && src_idx="$idx"
    [ "${chan_array[$idx]}" = "$frontier" ] && dst_idx="$idx"
  done
  local prior="${commit_array[$dst_idx]:--}" differs
  [ "$prior" = "-" ] && prior=""
  differs="$(_reusable_differs "$agent" "$cand" "$prior")"

  # Cumulative health since this candidate's own cut, across every concrete tier EXCEPT a ring
  # strictly BELOW the source that runs a DIFFERENT (newer) candidate (#1118 AC5): that ring's
  # failures belong to the newer candidate's own gate, so counting them here would let a churning
  # lower candidate block an older, independently-clean higher pair. In a single-candidate rollout
  # no ring is below the source with a different commit, so this is byte-identical to the prior
  # all-tiers scope; it diverges only when a newer candidate is soaking further down the pipeline.
  # Two scopes (#1176 + CodeRabbit on #1220): a tier that does NOT yet run the candidate (the
  # destination and beyond, tag provably on a different commit) has its failures attributed to the
  # release that actually ran, so old-release failures there never block. Every other tier — the
  # source tier and below, plus any tier whose commit is unknown — counts RAW, as before #1176:
  # the source tier's sample still includes runs from before the candidate reached it, so dropping
  # only their failures would let a candidate with no executions there reach PROMOTE.
  local raw_repos=() attr_repos=() ch3
  for idx in "${!chan_array[@]}"; do
    ch3="${chan_array[$idx]}"
    # Exclude a lower ring only when it PROVABLY runs a different commit. An unresolvable (empty)
    # tag is unknown, not "different": keep its failures in scope (fail closed).
    local lc="${commit_array[$idx]:--}"; [ "$lc" = "-" ] && lc=""
    if [ "$idx" -lt "$src_idx" ] && [ -n "$lc" ] && [ "$lc" != "$cand" ]; then
      continue
    fi
    while IFS= read -r r; do
      { [ -z "$r" ] || [ "$r" = '*' ]; } && continue
      if [ -n "$lc" ] && [ "$lc" != "$cand" ]; then attr_repos+=("$r"); else raw_repos+=("$r"); fi
    done < <(resolve_members "$agent" "$ch3")
  done
  # A repo that also belongs to a raw tier (e.g. the host, in both next and ring0) stays raw.
  local -A raw_set=(); local attr_only=()
  for r in ${raw_repos[@]+"${raw_repos[@]}"}; do raw_set["$r"]=1; done
  for r in ${attr_repos[@]+"${attr_repos[@]}"}; do [ -z "${raw_set["$r"]:-}" ] && attr_only+=("$r"); done
  local cum_fail cum_startup cum_benign cum_suspect cum_stale
  local a_fail a_startup a_benign a_suspect a_stale
  read -r cum_fail cum_startup cum_benign cum_suspect cum_stale < <(_cumulative_health "$agent" "$cut_z" "$differs" "-" ${raw_repos[@]+"${raw_repos[@]}"})
  read -r a_fail a_startup a_benign a_suspect a_stale < <(_cumulative_health "$agent" "$cut_z" "$differs" "$cand" ${attr_only[@]+"${attr_only[@]}"})
  cum_fail=$(( cum_fail + a_fail )); cum_startup=$(( cum_startup + a_startup ))
  cum_benign=$(( cum_benign + a_benign )); cum_suspect=$(( cum_suspect + a_suspect ))
  cum_stale=$(( cum_stale + a_stale ))
  # Target-ring health (#1176): failures from runs still on the previous release are reported,
  # never counted — the candidate cannot have caused them and may be the fix.
  if [ "${cum_stale:-0}" -gt 0 ]; then
    echo "::notice::target-ring health ($agent $transition): ${cum_stale} failure(s) in runs still on the previous release — informational, not counted against candidate ${cand:0:12}." >&2
  fi

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

  # A blind gate fails LOUDLY (#1224): a ring member whose runs could not be attributed is NOT
  # passing evidence. Name it in an ::error::, and hold an otherwise-clean gate (PROMOTE /
  # SOAKING / AWAITING_CONFIRMATION) as BLOCKED with triage UNRESOLVED so sync-issues tracks it.
  # A gate already BLOCKED by real failures keeps that (more specific) triage.
  local unresolved=""
  if [ -n "$uflag" ] && [ -s "$uflag" ]; then
    unresolved="$(cut -f1 "$uflag" | sort -u | paste -sd, - | sed 's/,/, /g')"
  elif [ -n "$uflag" ] && [ ! -e "$uflag" ]; then
    unresolved="(unresolved-member evidence could not be persisted)"
  elif [ -n "$uflag" ] && ! : >>"$uflag" 2>/dev/null; then
    # Empty but no longer writable: a failed append whose cleanup also failed (read-only fs) would
    # look clean here, so treat an unwritable flag as lost evidence.
    unresolved="(unresolved-member evidence could not be persisted)"
  fi
  if [ "$uflag_owned" -eq 1 ]; then
    # Keep a non-empty flag for _unresolved_evidence to reuse (it deletes it); drop an empty one.
    [ -n "$unresolved" ] || rm -f "$uflag"
    unset _CANARY_UNRESOLVED_FLAG
  fi
  if [ -n "$unresolved" ]; then
    echo "::error::canary gate for '$agent' [$transition] is BLIND on ring member(s) $unresolved — their runs could not be attributed (ADR-0007 ingress present, role job unresolvable). Counted as UNRESOLVED, not passing evidence; register the agent's ingress_job in the ring registry." >&2
    # PRE_EXISTING is advanceable via `promote --allow-pre-existing`, so UNRESOLVED must dominate it.
    if [ "$state" != "BLOCKED" ] || [ "$triage" = "PRE_EXISTING" ]; then
      state="BLOCKED"; triage="UNRESOLVED"; mix_shift="-"; downgrade="-"
    fi
  fi

  echo "${cand:--} $frontier $transition $state $dwell_h $dwell_floor $sample $target $cum_fail $cum_startup $cum_benign $triage $mix_shift $downgrade $dg_cand_rate $dg_cand_sample $dg_base_rate $dg_base_sample"
}

# _frontier_state <agent> — evaluate EVERY ring transition INDEPENDENTLY and echo ONE line per
# PENDING pair (#1118), each with the fields:
#   "<cand> <frontier> <transition> <state> <dwell_h> <dwell_floor> <sample> <target> <cum_fail> <cum_startup> <cum_benign> <triage> <mix_shift> <downgrade> <dg_cand_rate> <dg_cand_sample> <dg_base_rate> <dg_base_sample>"
# <cand> is "-" when the source ring's commit is unresolvable (a blank leading field would be collapsed
# by `read` and shift every field); consumers must never treat "-" as a SHA.
# For each adjacent src->dst, the candidate is channel_commit(src); the pair is PENDING (and a
# line emitted, computed by _pair_state) iff dst is not already on that candidate. Several pairs
# may be in flight at once — e.g. a newer candidate soaking at next->ring0 while an older one
# holds at ring1->stable, the exact case that used to be dropped when only next's candidate was
# evaluated. A ring only ever advances to the commit on the ring directly below it (channel_commit
# of the source), so no tier can be skipped. When no pair is pending the agent is fully rolled out
# and a single COMPLETE line is emitted (frontier="-"), preserving the shape every consumer keys
# off. triage is "-" unless a pair's state is BLOCKED (then REGRESSION | PRE_EXISTING | SUSPECT);
# mix_shift is "SHIFT" for a gate.correctness decision-mix hold (#668 L2); downgrade is
# "DOWNGRADE" when a SUSPECT auto-downgraded to PRE_EXISTING (#668 inc6).
_frontier_state() {
  local agent="$1" chans
  chans="$(ordered_channels "$agent")"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  # Resolve every ring's commit ONCE (channel_commit is uncached across calls; see _pair_state).
  local -a commits=() unknown=()
  local ch c u commits_csv=""
  while read -r ch c u; do
    [ "$c" = "-" ] && c=""
    commits+=("$c")
    unknown+=("$u")
    commits_csv+="${c:--},"
  done < <(_ring_commits "$agent" "$chans")
  commits_csv="${commits_csv%,}"
  local i prev="" cand dstc transition emitted=0
  for i in "${!chan_array[@]}"; do
    ch="${chan_array[$i]}"
    if [ -n "$prev" ]; then
      # The pair verdict is the pure core's (pair_verdict, #1242); this loop only acts on it. A ring
      # whose tag lookup ERRORED (#1225) is unknown, not absent.
      cand="${commits[$((i-1))]}"
      dstc="${commits[$i]}"
      transition="${prev}->${ch}"
      case "$(pair_verdict "${cand:--}" "${unknown[$((i-1))]:-0}" "${dstc:--}" "${unknown[$i]:-0}")" in
        ON_CANDIDATE) ;;
        PENDING|UNRESOLVABLE_SOURCE)
          # An UNRESOLVABLE src commit (empty) with a populated dst is still pending and _pair_state
          # holds it BLOCKED (fail closed, as the single-frontier code did) — never silently skipped
          # into a false COMPLETE.
          _pair_state "$agent" "$prev" "$ch" "$cand" "$transition" "$chans" "$commits_csv"
          emitted=1 ;;
        *)
          # HOLD_UNKNOWN (or any unrecognised verdict): hold the pair BLOCKED (fail closed) — comparing
          # an errored ring's empty commit would read an API outage as "on the candidate", and a total
          # outage as COMPLETE. Never evaluated (or promoted) by the gate (#1225).
          echo "::warning::$agent $transition: a ring tag lookup errored — holding the pair BLOCKED (fail closed) until it resolves (#1225)." >&2
          if [ -n "${_CANARY_TAG_GAP_FLAG:-}" ]; then
            printf '%s\n' "$transition" >> "$_CANARY_TAG_GAP_FLAG" 2>/dev/null || true
          fi
          echo "${cand:--} $ch $transition BLOCKED 0 0 0 0 0 0 0 - - - 0 0 0 0"
          emitted=1 ;;
      esac
    fi
    prev="$ch"
  done
  if [ "$emitted" -eq 0 ]; then
    echo "${commits[0]:--} - - COMPLETE 0 0 0 0 0 0 0 - -"
  fi
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
  echo "----"
  # Report EVERY pending pair independently (#1118): several transitions can be in flight at once.
  local frontier transition state dwell floor sample target cum_fail cum_startup cum_benign
  local triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample _pcand
  local any=0
  while read -r _pcand frontier transition state dwell floor sample target cum_fail cum_startup cum_benign triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample; do
    [ -z "$frontier" ] && continue
    if [ "$frontier" = "-" ]; then
      echo "frontier: none — fully rolled out (all rings on candidate)."
      any=1; continue
    fi
    any=1
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
      elif [ "$triage" = "UNRESOLVED" ]; then
        echo "::error::triage=UNRESOLVED — at least one ring member's runs could not be attributed (ADR-0007 collapsed repo: '$(_ingress_workflow)' present, no per-role workflow, role job unresolvable). The gate is blind there, so it holds rather than promote on incomplete evidence. Register the agent's ingress_job in the ring registry (#1224)."
      elif [ "$triage" = "FLAG_ERROR" ]; then
        echo "::error::triage=FLAG_ERROR — could not create the unresolved-member flag file (TMPDIR unwritable/full). The gate fails closed and holds; fix the runner's temp dir."
      elif [ "$triage" = "PRE_EXISTING" ]; then
        echo "::warning::triage=PRE_EXISTING — failure is pre-existing/environmental. Report only; do NOT rollback. Advances with --allow-pre-existing (or control.allow_pre_existing in the registry) once dwell/sample pass."
      else
        echo "::warning::state=BLOCKED (indeterminate) — could not resolve the candidate's cut date or a ring's channel tag (lookup error), so the gate fails closed and holds (not a detected failure; cum_fail=$cum_fail). Clears once the candidate's cut date/tag is resolvable."
      fi
    elif [ "$state" = "AWAITING_CONFIRMATION" ]; then
      echo "::notice::state=AWAITING_CONFIRMATION — reliability PASSED; holding for an opt-in human go/no-go at $transition (#668 Layer 3). Review the canary-confirm issue, then dispatch: promote $agent --confirm  (not --override)."
    fi
  done < <(_frontier_state "$agent")
  if [ "$any" -eq 0 ]; then
    echo "frontier: none — fully rolled out (all rings on candidate)."
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
  # Snapshot EVERY pending pair up front (#1118): each dst advances to the commit that was on its
  # src BEFORE any move this run, so a ring can never skip a tier even when several pairs advance
  # in one sweep, and pairs are decided INDEPENDENTLY — a BLOCKED lower pair never blocks a clean
  # higher pair, and `--confirm` clears only an AWAITING_CONFIRMATION pair.
  local -a _pairs=()
  # Arm the tag-gap flag so pairs held for an ERRORED ring tag lookup (#1225) are known and can
  # never be advanced — not even with --override (the destination ring is unresolved).
  local _gapflag _prev_gapflag="${_CANARY_TAG_GAP_FLAG:-}"
  _gapflag="$(mktemp 2>/dev/null || true)"
  if [ -z "$_gapflag" ]; then
    # Cannot arm the detector: with no marker an errored ring could still be overridden/promoted.
    echo "::error::promote $agent: cannot create the tag-gap marker file (temp filesystem unwritable) — failing closed, promoting nothing (#1225)." >&2
    return 1
  fi
  export _CANARY_TAG_GAP_FLAG="$_gapflag"
  mapfile -t _pairs < <(_frontier_state "$agent")
  local _gap_transitions=""
  if [ -n "$_gapflag" ]; then
    _gap_transitions="$(cat "$_gapflag" 2>/dev/null || true)"
    rm -f "$_gapflag"
    if [ -n "$_prev_gapflag" ]; then export _CANARY_TAG_GAP_FLAG="$_prev_gapflag"; else unset _CANARY_TAG_GAP_FLAG; fi
  fi
  # allow_pre: advance a BLOCKED pair ONLY when triage=PRE_EXISTING (never REGRESSION). Sourced
  # from the per-reusable control block or the --allow-pre-existing flag (#1025 P2). Computed once.
  local allow_pre
  allow_pre="$(_jq -r --arg a "$agent" '.agents[$a].gate?.control?.allow_pre_existing // false')"
  [ "$allow_pre_flag" = true ] && allow_pre=true
  # Consistent move (#1076): EVERY agent moves its channel tag via `gh api` on its HOST repo —
  # never a local `git push`. host defaults to THIS_REPO when the registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  local rc=0 pending=0 line first_pair=1 pair_override
  local cand frontier transition state _dwell _floor _sample _target cum_fail _cum_startup _cum_benign triage _mix_shift _dg _dgcr _dgcs _dgbr _dgbs
  for line in "${_pairs[@]}"; do
    read -r cand frontier transition state _dwell _floor _sample _target cum_fail _cum_startup _cum_benign triage _mix_shift _dg _dgcr _dgcs _dgbr _dgbs <<< "$line"
    { [ -z "$frontier" ] || [ "$frontier" = "-" ]; } && continue
    pending=1
    # --override is an operator decision about ONE promotion — the lowest pending pair, i.e. the
    # newest candidate, exactly what the single-frontier code overrode. It must NOT sweep every
    # in-flight pair: that could push an AWAITING_CONFIRMATION pair for a different candidate past
    # its human go/no-go (#1118 keeps that gate). Higher pairs are still decided by their own gates.
    pair_override=false
    if [ "$first_pair" -eq 1 ] && [ "$override" = true ]; then pair_override=true; fi
    first_pair=0
    # An unresolvable candidate ("-") cannot be promoted, even with --override: there is no commit to
    # move a tag to. It stays held BLOCKED (fail closed) until the source ring's tag resolves.
    if [ -n "$_gap_transitions" ] && grep -qxF -- "$transition" <<< "$_gap_transitions"; then
      echo "::error::gate=$state for '$frontier' [$transition] — a ring tag lookup errored; not promoting (even with --override). Clears once the tags resolve (#1225)." >&2
      continue
    fi
    if [ "$cand" = "-" ]; then
      echo "::error::gate=$state for '$frontier' [$transition] — the source ring's commit is unresolvable; not promoting (even with --override). Clears once the tag resolves." >&2
      continue
    fi
    # REGRESSION and SUSPECT both HALT + need a human: neither advances without --override, and
    # --allow-pre-existing (which only unblocks PRE_EXISTING) never advances them. For a SUSPECT
    # the human answers the class's discriminating question first (#668 increment 2).
    if [ "$state" = "BLOCKED" ] && { [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; } && [ "$pair_override" != true ]; then
      echo "::error::gate=BLOCKED (triage=$triage) for '$frontier' [$transition] — candidate regression suspected; not promoting. Investigate + rollback, do not --override blindly."
      continue
    fi
    local advance=false
    [ "$state" = "PROMOTE" ] && advance=true
    [ "$pair_override" = true ] && advance=true
    [ "$state" = "BLOCKED" ] && [ "$triage" = "PRE_EXISTING" ] && [ "$allow_pre" = true ] && advance=true
    # Layer 3 (#668 increment 3): a human --confirm advances an AWAITING_CONFIRMATION pair
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
      continue
    fi
    if [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$confirm" = true ]; then
      echo "::notice::human confirmation received (--confirm) — advancing $agent/$frontier [$transition] past the confirmation go/no-go (reliability was already PROMOTE)."
    elif [ "$state" != "PROMOTE" ]; then
      echo "::warning::advancing $agent/$frontier despite gate state '$state' (triage=$triage)"
    fi
    # Move the RESOLVED frontier tag (major-scoped-channels epic #657, F4): advance the v-scoped
    # `<agent>/v<M>-<tier>` within its major line when it exists, else the legacy bare
    # `<agent>/<tier>`. The logical tier ($frontier) is unchanged — it still drives the gate + is
    # reported as promoted_ring.
    local frontier_tag; frontier_tag="$(_resolved_channel_tag "$agent" "$frontier")"
    echo "advancing $frontier_tag -> ${cand:0:12} on $host"
    if [ "$dry" = true ]; then
      echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$frontier_tag sha=$cand (force)"
      continue
    fi
    if ! _gh_move_tag "$host" "$frontier_tag" "$cand"; then
      echo "::error::failed to move $frontier_tag -> ${cand:0:12} on $host" >&2
      # Persist this FAILED tag write (#1023 defect 2). It is UNEXPECTED — a permission/API
      # rejection on the WRITE — distinct from an expected gate-block, which never reaches the move.
      _log_promotion_failure "$agent" "$frontier" "$cand" "$host" "tag write rejected ($frontier_tag on $host)"
      rc=1
      continue
    fi
    echo "promoted $frontier_tag -> ${cand:0:12}"
    # Expose the move for the workflow's GitHub Deployment (traceability, #502). The deployment must
    # be created on the repo that OWNS the moved commit (#1059). GITHUB_OUTPUT is single-valued
    # (last write wins); the workflow reads CANARY_PROMOTIONS_LOG — one TSV line per move — to
    # record a deployment for EVERY promotion (a run may now advance several rings, #1118).
    local deploy_repo="$host"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      { echo "promoted_agent=$agent"; echo "promoted_ring=$frontier"
        echo "promoted_sha=$cand";   echo "promoted_host=$deploy_repo"; } >> "$GITHUB_OUTPUT"
    fi
    if [ -n "${CANARY_PROMOTIONS_LOG:-}" ]; then
      printf '%s\t%s\t%s\t%s\n' "$agent" "$frontier" "$cand" "$deploy_repo" >> "$CANARY_PROMOTIONS_LOG"
    fi
  done
  [ "$pending" -eq 0 ] && echo "nothing to promote — $agent is fully rolled out."
  return "$rc"
}

# _log_promotion_failure <agent> <ring> <cand> <host> <reason> — append a FAILED tag-write to the
# SIBLING failure log (#1023 defect 2), the counterpart of the CANARY_PROMOTIONS_LOG success log.
# Only genuine write failures land here (the caller is cmd_promote's post-move error path) — a
# gate-blocked promotion returns before the move and is NEVER recorded, keeping the two concerns
# distinct: an expected gate-block stays the canary-blocker issue's job; an unexpected tag-write
# failure is what this log (and sync-promotion-failures) escalates. No-op when the log is unset.
_log_promotion_failure() {
  [ -n "${CANARY_PROMOTIONS_FAILED_LOG:-}" ] || return 0
  if ! printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$CANARY_PROMOTIONS_FAILED_LOG"; then
    echo "::warning::could not append failure record for $1 to ${CANARY_PROMOTIONS_FAILED_LOG} (unwritable path?); tag-write failure may not be escalated." >&2
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
  local failed=()
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_promote "$agent" "$@" || { rc=$?; echo "::warning::promote of $agent returned $rc (continuing fleet)"; failed+=("$agent($rc)"); }
  done <<< "$agents"
  # A per-agent promote failure is deliberately ISOLATED (logged "continuing fleet" above) so one
  # agent cannot halt the sweep — but propagating its rc also took the whole scheduled promote-all
  # red every 4h (#1019), even for a per-agent failure already surfaced as a ::warning:: and, when
  # it is a held/blocked promotion, tracked by sync-issues. Return success from the fleet sweep;
  # genuine per-agent failures remain visible in the log and the blocker-issue path, not via a red
  # scheduled run. (A single-agent `promote <agent>` still returns that agent's real exit code.)
  #
  # BUT a green run must not imply "everything promoted" (#1019 review): with the rc swallowed, a
  # permission or API rejection would otherwise be indistinguishable from a clean sweep unless
  # someone read the whole log. Emit ONE aggregated summary naming every failed agent, so the
  # failure is visible at a glance in the job summary while the sweep still exits 0.
  if [ ${#failed[@]} -gt 0 ]; then
    echo "::warning title=promote-all: ${#failed[@]} agent(s) failed::${failed[*]} — the sweep still exits 0 by design (#1019); investigate these before trusting a green promote-all."
    echo "promote-all summary: ${#failed[@]} failed — ${failed[*]}"
  else
    echo "promote-all summary: all agents promoted or already current."
  fi
  return 0
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
  local agent="$1" cand="$2" cut_z repo json r n=0 out=""
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  [ -z "$cut_z" ] && { printf '_(no candidate cut date resolved — cannot list failing runs)_\n'; return 0; }
  local chan_array=() ch all=() seen=" " dedup=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  for ch in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all+=("$r"); done < <(resolve_members "$agent" "$ch")
  done
  for r in "${all[@]}"; do case "$seen" in *" $r "*) ;; *) dedup+=("$r"); seen+="$r ";; esac; done
  # Same attribution scope as _pair_state: only a repo that belongs solely to tiers provably NOT on
  # the candidate has its old-release failures skipped; any repo in a tier on (or of unknown) commit
  # lists every failure, so the evidence matches cum_fail.
  local -A raw_evidence=(); local ev_c
  for ch in "${chan_array[@]}"; do
    ev_c="$(channel_commit "$agent" "$ch" || true)"
    if [ -z "$ev_c" ] || [ "$ev_c" = "$cand" ]; then
      while IFS= read -r r; do [ -n "$r" ] && raw_evidence["$r"]=1; done < <(resolve_members "$agent" "$ch")
    fi
  done
  for repo in "${dedup[@]}"; do
    json="$(_agent_run_json "$agent" "$repo" "$cut_z")"
    local rid rrole sig
    local concl
    while IFS=$'\t' read -r rid concl rrole; do
      [ -z "$rid" ] && continue
      # Old release: not counted (#1176). Only `failure` runs are attributable — a startup_failure
      # never ran a job, so it has no "Uses:" line and always counts (cum_startup), like the gate.
      if [ "$concl" = "failure" ] && [ -z "${raw_evidence["$repo"]:-}" ] && _run_is_stale "$agent" "$cand" "$repo" "$rid"; then continue; fi
      if [ "$n" -ge 8 ]; then out+="- _(…more failing runs; truncated at 8)_"$'\n'; printf '%s' "$out"; return 0; fi
      sig="$(_run_signature "$repo" "$rid" "$rrole" | tr '\n' ';' | sed 's/;$//')"
      out+="- \`$repo\` — run [$rid](https://github.com/$repo/actions/runs/$rid); failed steps: ${sig:-unknown}"$'\n'
      n=$((n+1))
    done < <(jq -r '.[]?|select(.conclusion=="failure" or .conclusion=="startup_failure")|[(.databaseId|tostring),.conclusion,(.role // "")]|@tsv' 2>/dev/null <<< "$json")
  done
  [ -z "$out" ] && out="_(no failing runs in the per-candidate window — cum_fail may be startup_failures or a transient count)_"$'\n'
  printf '%s' "$out"
}

# _unresolved_evidence <agent> <candidate_commit> — markdown bullets naming each ring member whose
# runs could not be attributed (#1224), with the reason. Re-walks the same per-candidate window
# and tier repos as _blocker_evidence under a fresh UNRESOLVED flag.
_unresolved_evidence() {
  local agent="$1" cand="$2" flag repo reason out="" flag_is_persistent=0 reuse=0
  # Reuse the flag left by _frontier_state (a caller's pre-armed flag first) to avoid re-walking (#1224)
  flag="${_CANARY_UNRESOLVED_FLAG:-$(_unresolved_flag_path "$agent" "$cand")}"
  if [ -s "$flag" ]; then
    flag_is_persistent=1
    # A caller-armed flag belongs to the caller; only delete our own per-process one.
    [ -z "${_CANARY_UNRESOLVED_FLAG:-}" ] && reuse=1
  else
    # Flag not found or empty, create a new one and re-evaluate
    flag="$(mktemp 2>/dev/null || echo "")"
    [ -z "$flag" ] && { printf '_(could not list the unresolved members — see the workflow log ::error:: annotations)_\n'; return 0; }
    _CANARY_UNRESOLVED_FLAG="$flag" _blocker_evidence "$agent" "$cand" >/dev/null 2>&1 || true
  fi
  while IFS=$'\t' read -r repo reason; do
    [ -n "$repo" ] && out+="- \`$repo\` — $reason"$'\n'
  done < <(sort -u "$flag")
  if [ "$flag_is_persistent" -eq 0 ] || [ "$reuse" -eq 1 ]; then rm -f "$flag"; fi
  [ -z "$out" ] && out="_(no unresolved member found in the blocker scope on re-check — the hold may come from the baseline window or an unpersisted evidence flag; it re-evaluates next tick)_"$'\n'
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

# _blocker_body <agent> <transition> <cand> <cum_fail> <cum_startup> <triage> <host> <evidence> [<mix_shift>] [<mix_table>] [<downgrade>] [<dg_cand_rate>] [<dg_cand_sample>] [<dg_base_rate>] [<dg_base_sample>] [<data_gap>]
_blocker_body() {
  local agent="$1" transition="$2" cand="$3" cum_fail="$4" cum_startup="$5" triage="$6" host="$7" evidence="$8" mix_shift="${9:--}" mix_table="${10:-}" note
  local downgrade="${11:--}" dg_cand_rate="${12:-0}" dg_cand_sample="${13:-0}" dg_base_rate="${14:-0}" dg_base_sample="${15:-0}" data_gap="${16:-0}"
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
  elif [ "$triage" = "UNRESOLVED" ]; then
    note="> ⚠️ **UNRESOLVED (gate blind on a ring member, #1224)** — at least one ring member is an ADR-0007 collapsed repo (its per-role workflow is gone, \`$(_ingress_workflow)\` is present) and this agent's runs there could not be attributed to its role job. That member is **not** counted as passing evidence, so the gate holds instead of promoting on incomplete evidence. This is **not** a detected run failure (cumulative failures: $cum_fail). Fix: register the agent's \`ingress_job\` (its job key in the ingress) in \`standards/canary-rings.json\`. If the evidence below says job reads were capped, the ingress has more runs in the window than \`CANARY_INGRESS_JOBS_MAX\` allows: raise that knob (default 300) instead. This issue auto-closes once every member resolves."
  elif [ "$triage" = "FLAG_ERROR" ]; then
    note="> ⚠️ **FLAG_ERROR (gate held — runner temp dir unwritable)** — the candidate's cut date resolved fine, but the gate could not create its unresolved-member flag file (\`TMPDIR\` unwritable or full), so it could not record unattributable ring members and fails closed rather than promote on possibly incomplete evidence. This is **not** a detected run failure (cumulative failures: $cum_fail). Fix: free space / make \`TMPDIR\` writable on the runner; this clears on the next tick."
  elif [ "$triage" = "PRE_EXISTING" ]; then
    note="> ⚠️ **PRE_EXISTING** — the failure is pre-existing/environmental (reusable byte-identical to the prior channel). Report only; the gate will not roll back or advance. Fix-forward, and the armed timer auto-promotes once clean."
  else
    # Fail-closed hold (_frontier_state: cut_z empty) — state=BLOCKED but triage="-" and cum_fail=0.
    # There is no detected failure; the gate could not resolve the candidate's cut date, so it
    # holds rather than evaluate an unbounded window. Do NOT claim PRE_EXISTING here (there is
    # nothing environmental to report) — say what actually happened.
    note="> ℹ️ **INDETERMINATE (gate held — candidate cut date unresolved)** — the gate could not resolve this candidate's cut date, so it fails closed and holds the promotion instead of evaluating an unbounded run history. This is **not** a detected run failure (cumulative failures: $cum_fail). It usually clears on its own once the candidate's release tag/cut date becomes resolvable; if it persists, verify that candidate \`${cand:0:12}\` is a tagged, resolvable commit on \`$host\`."
  fi
  # Data-gap fail-closed (#820): run history was unreadable this tick, so the cumulative counts
  # are NOT reliable and the triage verdict rests on the reusable diff alone. Prepend a banner
  # (before the triage note) and blank out the misleading "0" cumulative-failures cell.
  local cum_row="**$cum_fail** (startup_failures: $cum_startup)"
  local evidence_heading="Failing runs in the per-candidate window"
  [ "$triage" = "UNRESOLVED" ] && evidence_heading="Unresolved ring members"
  if [ "$data_gap" = "2" ]; then
    cum_row="_unknown — channel tags unresolved this tick_"
    note="> ⚠️ **TAG LOOKUP FAILED — FAILING CLOSED.** A channel-tag lookup for this pair errored this tick (a GitHub API failure — see the workflow log — not an absent tag), so the gate cannot tell where the rings are. Rather than report a false \"fully rolled out\", it holds the promotion and keeps this issue open. This clears automatically once the tags resolve again and the gate re-evaluates (#1225)."
  elif [ "$data_gap" = "1" ]; then
    cum_row="_unknown — run history unavailable this tick_"
    note="> ⚠️ **PARTIAL DATA (run-history fetch failed) — FAILING CLOSED.** The canary gate could not read this agent's recent run history this tick (a sustained GitHub API failure — see the workflow log). Rather than report a false all-clear, the gate holds the promotion and keeps this issue open. The cumulative counts below are **not reliable for this tick**; the triage verdict is derived from the reusable diff alone. This clears automatically once run history is readable again and the gate re-evaluates.
>
$note"
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
| cumulative failures | $cum_row |
| triage | **$triage** |

$note

### $evidence_heading
$evidence
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
}

# _confirm_body <agent> <transition> <cand> <prior> <host> <sample> <target> — the body of the
# evidence-carrying human-confirmation issue for an AWAITING_CONFIRMATION frontier (#668 Layer 3).
# Reliability has PASSED; a human confirms the candidate is behaving CORRECTLY (not merely exiting
# green) before it reaches the stable tier (all consumers). Marker-keyed on the AGENT AND the
# ring1 CANDIDATE (canary-confirm:<agent>:<cand>) so sync-issues upserts it idempotently, keeps it
# open across newer cuts landing on next/ring0 (the candidate is unchanged), and closes it only
# when stable advances or the ring1 candidate itself changes — a recut ring1 candidate never
# silently inherits a human's pending go/no-go for a different commit (#1118 AC3).
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
<!-- canary-confirm:$agent:$cand -->
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

# _frontier_state_resilient <agent> — sync-issues resilience wrapper (#820). _frontier_state
# reads run history (_run_json), and on a SUSTAINED fetch failure (#738 fail-closed) it does
# NOT cleanly stop: command substitutions don't inherit errexit, so it limps on and emits a
# misleadingly-CLEAN state line (or aborts to empty). Either way sync-issues could no longer
# tell a CLEARED agent from an UNREADABLE one — silently dropping (or auto-closing) a
# regression's tracked issue: the safety net defeated by exactly the failures it should record.
# So _run_json records each fetch failure to a file flag we arm here; when it fires we DISCARD
# _frontier_state's output and instead determine everything that does NOT need run history
# (candidate, frontier, transition, reusable-differs → triage) from tag/blob resolution, and
# FAIL CLOSED to BLOCKED so the tracked issue is upserted (never a green no-op). Emits the 18
# _frontier_state fields PLUS a trailing DATA-GAP flag (0=normal state resolved, 1=partial
# run-history). Returns NON-ZERO only when even the candidate/frontier cannot be resolved — a
# TOTAL inability stays a hard error, surfaced by the caller. Since #1118 _frontier_state emits
# one line per PENDING pair, so the wrapper appends the datagap flag to EACH line and, on a data
# gap, reconstructs one BLOCKED line per pending pair.
# A TAG-lookup error (#1225) is a second kind of data gap: the pair(s) touching a ring whose tag
# lookup errored are held BLOCKED by _frontier_state and tagged datagap=2 here, so sync-issues
# keeps their issues open and fails closed instead of reading an API outage as "gate cleared".
_frontier_state_resilient() {
  local agent="$1" out="" rc=0 fetch_failed=0
  # Arm a file flag that _run_json appends to on a sustained fetch failure. A file (not a shell
  # var) is used because _frontier_state runs in a command-substitution subshell, and a var set
  # there would not survive back to us — the file does. The tag-gap flag (#1225) collects the
  # transitions _frontier_state held because a ring's tag lookup errored.
  local flag gapflag gaps=""
  flag="$(mktemp 2>/dev/null || echo "")"
  gapflag="$(mktemp 2>/dev/null || echo "")"
  if [ -z "$flag" ] || [ -z "$gapflag" ]; then
    # Cannot arm a failure detector at all — treat as an unreadable tick rather
    # than silently falling back to the old undetectable-outage behavior.
    fetch_failed=1
    out="$(_frontier_state "$agent")" || rc=$?
  else
    # `|| rc=$?` catches any abort so set -e does not tear down the fleet loop on one agent.
    export _CANARY_FETCH_FAIL_FLAG="$flag" _CANARY_TAG_GAP_FLAG="$gapflag"
    out="$(_frontier_state "$agent")" || rc=$?
    unset _CANARY_FETCH_FAIL_FLAG _CANARY_TAG_GAP_FLAG
    [ -s "$flag" ] && fetch_failed=1
    gaps="$(<"$gapflag")"
  fi
  [ -n "$flag" ] && rm -f "$flag"
  [ -n "$gapflag" ] && rm -f "$gapflag"
  # Normal path (no fetch failure, state lines produced): transparent pass-through, datagap=0
  # appended to EVERY pending-pair line (#1118) — or 2 for a pair held on a tag-lookup error.
  if [ "$fetch_failed" -eq 0 ] && [ -n "$out" ] && [ "$rc" -eq 0 ]; then
    local line ltr gap
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local temp="${line#* }"
      temp="${temp#* }"
      ltr="${temp%% *}"
      gap=0
      [[ $'\n'"$gaps"$'\n' == *$'\n'"$ltr"$'\n'* ]] && gap=2
      printf '%s %s\n' "$line" "$gap"
    done <<< "$out"
    return 0
  fi
  # Non-data-gap _frontier_state failure: the fetch succeeded but _frontier_state still failed —
  # propagate the error rather than mis-annotating it as a data gap and emitting datagap=1.
  if [ "$fetch_failed" -eq 0 ]; then
    [ "$rc" -ne 0 ] && return "$rc"
    return 1
  fi
  # Data gap: the run-history fetch failed — reconstruct the tag-only facts for EVERY pending pair
  # (none read run history). Each is failed CLOSED to BLOCKED so its tracked issue is upserted.
  local chans; chans="$(ordered_channels "$agent" || true)"
  local prev="" prev_commit="" prev_unknown=0 ch ch_commit ch_unknown cand dstc transition prior differs triage emitted=0
  while read -r ch ch_commit ch_unknown; do   # once per ring (uncached across calls)
    [ -n "$ch" ] || continue
    [ "$ch_commit" = "-" ] && ch_commit=""
    if [ -n "$prev" ]; then
      cand="$prev_commit"
      dstc="$ch_commit"
      # A ring whose tag lookup errored (#1225) is unknown: hold the pair BLOCKED, tag-gap.
      if [ "$prev_unknown" = 1 ] || [ "$ch_unknown" = 1 ]; then
        echo "${cand:--} $ch ${prev}->${ch} BLOCKED 0 0 0 0 0 0 0 - - - 0 0 0 0 2"
        emitted=1
        prev="$ch"; prev_commit="$ch_commit"; prev_unknown="$ch_unknown"
        continue
      fi
      # Same pure pair verdict as _frontier_state (#1242): a pending pair, including an unresolvable
      # (empty) src commit, stays tracked as BLOCKED rather than vanishing (fail closed); anything
      # other than ON_CANDIDATE is held.
      if [ "$(pair_verdict "${cand:--}" "$prev_unknown" "${dstc:--}" "$ch_unknown")" != "ON_CANDIDATE" ]; then
        transition="${prev}->${ch}"
        prior="$dstc"
        differs="$(_reusable_differs "$agent" "$cand" "$prior")"
        # classify_failure with an unknown category + no suspect signal: differs=1 → REGRESSION
        # (fail closed — a changed reusable with UNREADABLE health is a suspected regression that
        # needs a human), differs=0 → PRE_EXISTING (a byte-identical reusable cannot be a
        # candidate regression). Either verdict still tracks the pair as BLOCKED.
        triage="$(classify_failure "$differs" unknown 0)"
        echo "${cand:--} $ch $transition BLOCKED 0 0 0 0 0 0 0 $triage - - 0 0 0 0 1"
        emitted=1
      fi
    fi
    prev="$ch"; prev_commit="$ch_commit"; prev_unknown="$ch_unknown"
  done < <(if [ -n "$chans" ]; then _ring_commits "$agent" "$chans"; fi)
  # Total inability: cannot resolve even one pending pair → hard error. Fail closed (never a silent
  # green); the caller surfaces ::error:: and ends non-zero.
  [ "$emitted" -eq 0 ] && return 1
  return 0
}

# _confirm_issues_for_agent <agent> — "<number>\t<STATE>" per canary-confirm issue whose marker
# belongs to <agent>, matching BOTH the legacy agent-only marker (`canary-confirm:<agent>`) and
# the #1118 agent:candidate marker (`canary-confirm:<agent>:<cand>`). Used to close any confirm
# issue that is no longer the current ring1 candidate's — so a recut ring1 candidate (or a
# no-longer-awaiting agent) never leaves a stale go/no-go issue open. Empty if none.
_confirm_issues_for_agent() {
  local agent="$1"
  gh issue list --repo "$ISSUE_REPO" --label canary-confirm --state all -L 100 \
      --json number,state,body 2>/dev/null \
    | jq -r --arg a "$agent" \
        '.[] | select((.body // "") | test("<!-- canary-confirm:" + $a + "(:[^ ]+)? -->"))
         | [(.number|tostring), (.state|ascii_upcase)] | @tsv' 2>/dev/null \
    || echo ""
}

# cmd_sync_issues [--dry-run] — upsert one blocker issue per BLOCKED agent, and render the
# fleet-status table into the run's job summary (GITHUB_STEP_SUMMARY). Blocker issues are
# idempotent (marker-keyed) and auto-close when the gate clears. Best-effort for issue-write
# failures (never aborts mid-fleet), but FAILS CLOSED (non-zero) when an agent's state is
# totally undeterminable — a green no-op would mask a regression (#820). Reads ISSUE_REPO
# (default THIS_REPO).
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
  local rows="" agent hard_fail=0
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    # Resilient read (#820), now per PENDING pair (#1118): the wrapper fails closed to a
    # BLOCKED+datagap line per pending pair on a run-history fetch outage, and returns non-zero
    # (no output) only on a TOTAL inability to determine state. A non-zero here means we could not
    # resolve even one pair — fail closed rather than report a false all-clear (a green no-op could
    # mask a regression).
    local pairs_out pairs_rc=0
    pairs_out="$(_frontier_state_resilient "$agent")" || pairs_rc=$?
    if [ "$pairs_rc" -ne 0 ]; then
      echo "::error::sync-issues: cannot determine canary state for '$agent' (run-history AND tag resolution unavailable) — failing closed rather than reporting a false all-clear." >&2
      hard_fail=1
      rows+="| \`$agent\` | UNKNOWN | \`-\` | ? | ? | ⚠️ data unavailable (fail-closed) |"$'\n'
      continue
    fi
    local host; host="$(_agent_field "$agent" host)"
    local cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift
    local downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample datagap
    # Pass 1: select the blocker pair (first BLOCKED) and the confirm pair (first AWAITING). The two
    # concerns are independent (#1118 AC5), so a BLOCKED lower pair and an AWAITING higher pair are
    # tracked by SEPARATE issues in the same tick.
    local have_blocked=0 bl_cand="" bl_transition="" bl_triage="-" bl_cum_fail=0 bl_cum_startup=0
    local bl_mix_shift="-" bl_downgrade="-" bl_dgcr=0 bl_dgcs=0 bl_dgbr=0 bl_dgbs=0 bl_datagap=0
    local have_awaiting=0 cf_cand="" cf_transition="" cf_sample=0 cf_target=0 tag_gap=0
    while read -r cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample datagap; do
      { [ -z "$frontier" ] || [ "$frontier" = "-" ]; } && continue
      [ "${datagap:-0}" = "2" ] && tag_gap=1
      # Blocker source priority: a substantive REGRESSION/SUSPECT pair outranks a tag-lookup-error pair
      # (datagap=2), which outranks an ordinary BLOCKED pair — so an active regression's escalation
      # (needs-human) is never replaced by the outage's `-` triage, while the outage still beats
      # unrelated run evidence. The outage itself is surfaced via tag_gap (hard_fail + dashboard).
      local _rank=1 _bl_rank=1
      { [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; } && _rank=3
      [ "${datagap:-0}" = "2" ] && _rank=2
      { [ "$bl_triage" = "REGRESSION" ] || [ "$bl_triage" = "SUSPECT" ]; } && _bl_rank=3
      [ "$bl_datagap" = "2" ] && _bl_rank=2
      if [ "$state" = "BLOCKED" ] && { [ "$have_blocked" -eq 0 ] || [ "$_rank" -gt "$_bl_rank" ]; }; then
        have_blocked=1
        bl_cand="$cand"; bl_transition="$transition"; bl_triage="$triage"
        bl_cum_fail="$cum_fail"; bl_cum_startup="$cum_startup"; bl_mix_shift="$mix_shift"
        bl_downgrade="$downgrade"; bl_dgcr="$dg_cand_rate"; bl_dgcs="$dg_cand_sample"
        bl_dgbr="$dg_base_rate"; bl_dgbs="$dg_base_sample"; bl_datagap="${datagap:-0}"
      fi
      if [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$have_awaiting" -eq 0 ]; then
        have_awaiting=1
        cf_cand="$cand"; cf_transition="$transition"; cf_sample="$_s"; cf_target="$_t"
      fi
    done <<< "$pairs_out"
    # A ring's tag lookup ERRORED this tick (#1225): the pairs touching it are held BLOCKED, but the
    # agent's true state is unknown — fail closed (non-zero, like a total run-history outage) and
    # never close an issue on the strength of it (handled below).
    if [ "$tag_gap" -eq 1 ]; then
      echo "::error::sync-issues: a channel-tag lookup for '$agent' errored (API failure, not an absent tag) — holding the affected pair(s) BLOCKED and failing closed rather than reporting a false all-clear." >&2
      hard_fail=1
    fi

    # Blocker issue (per agent, keyed canary-blocker:<agent>). Driven by the selected BLOCKED pair.
    local bl_link="—" num_state num istate
    num_state="$(_issue_find canary-blocker "<!-- canary-blocker:$agent -->" || true)"
    num="${num_state%%$'\t'*}"; istate="${num_state##*$'\t'}"
    if [ "$have_blocked" -eq 1 ]; then
      local evidence body title mix_table=""
      if [ "$bl_datagap" = "2" ]; then
        evidence="_(⚠️ a channel-tag lookup failed this tick, so this pair's rings could not be resolved and no failing runs can be attributed. The gate FAILS CLOSED: the promotion is held and this issue stays open until the tags resolve again.)_"
      elif [ "$bl_datagap" = "1" ]; then
        evidence="_(⚠️ run-history fetch failed this tick — the failing runs could not be listed. The gate FAILS CLOSED: the promotion is held and this issue stays open until run history is readable again and the gate can re-evaluate.)_"
      elif [ "$bl_triage" = "UNRESOLVED" ]; then
        evidence="$(_unresolved_evidence "$agent" "$bl_cand" || true)"
      elif [ "$bl_triage" = "FLAG_ERROR" ]; then
        evidence="_(the gate could not create its unresolved-member flag file in \`TMPDIR\`, so no run evidence was gathered this tick. It FAILS CLOSED and holds this pair until the temp dir is writable.)_"
      else
        if [ "$bl_cand" = "-" ]; then
          evidence="_(the source ring's commit is unresolvable this tick, so there is no candidate whose failing runs can be listed. The gate FAILS CLOSED and holds this pair until the tag resolves.)_"
        else
          evidence="$(_blocker_evidence "$agent" "$bl_cand" || true)"
        fi
      fi
      [ "$bl_mix_shift" = "SHIFT" ] && mix_table="$(_decision_mix_table "$agent" "$bl_cand" "$bl_transition" || true)"
      body="$(_blocker_body "$agent" "$bl_transition" "$bl_cand" "$bl_cum_fail" "$bl_cum_startup" "$bl_triage" "$host" "$evidence" "$bl_mix_shift" "$mix_table" "$bl_downgrade" "$bl_dgcr" "$bl_dgcs" "$bl_dgbr" "$bl_dgbs" "$bl_datagap")"
      if [ "$bl_mix_shift" = "SHIFT" ]; then
        title="Canary blocker: $agent $bl_transition (decision-mix shift, SUSPECT)"
      elif [ "$bl_datagap" = "2" ]; then
        title="Canary blocker: $agent $bl_transition (tag lookup failed — fail-closed)"
      elif [ "$bl_datagap" = "1" ]; then
        title="Canary blocker: $agent $bl_transition ($bl_triage, partial run-history — fail-closed)"
      else
        title="Canary blocker: $agent $bl_transition (cum_fail=$bl_cum_fail, $bl_triage)"
      fi
      if [ -z "$num" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN blocker issue for $agent ($bl_triage)"; bl_link="(new)"; else
          num="$(_gh_issue_create "$title" "$body" "canary-blocker" || true)"
          if [ -n "$num" ]; then
            gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead >/dev/null 2>&1 || true
            { [ "$bl_triage" = "REGRESSION" ] || [ "$bl_triage" = "SUSPECT" ]; } && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened blocker issue #$num for $agent"; bl_link="#$num"
          else echo "::warning::could not open blocker issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE blocker issue #$num for $agent"; bl_link="#$num"; else
          [ "$istate" = "OPEN" ] || gh issue reopen "$num" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$num" --repo "$ISSUE_REPO" --title "$title" --body "$body" >/dev/null 2>&1 \
            || echo "::warning::could not update blocker issue #$num for $agent"
          gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead >/dev/null 2>&1 || true
          if [ "$bl_triage" = "REGRESSION" ] || [ "$bl_triage" = "SUSPECT" ]; then
            gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          else
            gh issue edit "$num" --repo "$ISSUE_REPO" --remove-label needs-human >/dev/null 2>&1 || true
          fi
          echo "  updated blocker issue #$num for $agent"; bl_link="#$num"
        fi
      fi
    else
      # No BLOCKED pair — close a stale open blocker issue (the gate cleared). Never on a tag gap
      # (#1225): an unresolved ring is not a cleared gate.
      if [ -n "$num" ] && [ "$istate" = "OPEN" ] && [ "$tag_gap" -eq 0 ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared blocker issue #$num for $agent"; else
          gh issue close "$num" --repo "$ISSUE_REPO" \
            --comment "✅ Gate cleared — \`$agent\` is no longer BLOCKED. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed cleared blocker issue #$num for $agent"
        fi
        bl_link="#$num (closed)"
      fi
    fi

    # Layer 3 (#668 increment 3, #1118 AC3): the human go/no-go issue for an AWAITING_CONFIRMATION
    # pair, keyed on the AGENT and the ring1 CANDIDATE (canary-confirm:<agent>:<cand>). Keyed on the
    # candidate so it PERSISTS across newer cuts landing on next/ring0 (the candidate is unchanged)
    # and closes only when stable advances or the ring1 candidate itself changes. Labelled
    # needs-human — a human confirms; dev-lead does not action it.
    local cf_link="—" cnum_state cnum cistate keep_num=""
    if [ "$have_awaiting" -eq 1 ]; then
      local cf_dst prior cbody ctitle
      cf_dst="${cf_transition##*->}"
      prior="$(channel_commit "$agent" "$cf_dst" || true)"
      cbody="$(_confirm_body "$agent" "$cf_transition" "$cf_cand" "$prior" "$host" "$cf_sample" "$cf_target" || true)"
      ctitle="Canary confirm: $agent $cf_transition — human go/no-go before stable"
      cnum_state="$(_issue_find canary-confirm "<!-- canary-confirm:$agent:$cf_cand -->" || true)"
      cnum="${cnum_state%%$'\t'*}"; cistate="${cnum_state##*$'\t'}"
      if [ -z "$cnum" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN confirm issue for $agent"; cf_link="(new confirm)"; else
          cnum="$(_gh_issue_create "$ctitle" "$cbody" "canary-confirm" || true)"
          if [ -n "$cnum" ]; then
            gh issue edit "$cnum" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened confirm issue #$cnum for $agent"; cf_link="#$cnum (confirm)"
          else echo "::warning::could not open confirm issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE confirm issue #$cnum for $agent"; cf_link="#$cnum (confirm)"; else
          [ "$cistate" = "OPEN" ] || gh issue reopen "$cnum" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$cnum" --repo "$ISSUE_REPO" --title "$ctitle" --body "$cbody" >/dev/null 2>&1 \
            || echo "::warning::could not update confirm issue #$cnum for $agent"
          gh issue edit "$cnum" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          echo "  updated confirm issue #$cnum for $agent"; cf_link="#$cnum (confirm)"
        fi
      fi
      keep_num="$cnum"
    fi
    # Close any confirm issue for this agent that is NOT the current ring1 candidate's (a recut
    # ring1 candidate, or an agent no longer awaiting at all) — a stale go/no-go must never linger.
    # Skipped on a tag gap (#1225): with a ring unresolved we cannot tell stale from still-pending.
    local ci_num ci_state
    while IFS=$'\t' read -r ci_num ci_state; do
      [ -z "$ci_num" ] && continue
      [ "$tag_gap" -eq 1 ] && continue
      [ -n "$keep_num" ] && [ "$ci_num" = "$keep_num" ] && continue
      [ "$ci_state" = "OPEN" ] || continue
      if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared confirm issue #$ci_num for $agent"; else
        gh issue close "$ci_num" --repo "$ISSUE_REPO" \
          --comment "✅ No longer awaiting confirmation for this candidate — \`$agent\` go/no-go is stale. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
        echo "  closed cleared confirm issue #$ci_num for $agent"
      fi
      [ "$cf_link" = "—" ] && cf_link="#$ci_num (confirm closed)"
    done < <(_confirm_issues_for_agent "$agent")

    # Pass 2: one dashboard row per pending pair (a COMPLETE agent gets a single COMPLETE row).
    local rendered=0 disp_tr link
    while read -r cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample datagap; do
      [ -z "$state" ] && continue
      disp_tr="$transition"; [ "$frontier" = "-" ] && disp_tr="-"
      link="—"
      [ "$state" = "BLOCKED" ] && [ "$transition" = "$bl_transition" ] && link="$bl_link"
      [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$transition" = "$cf_transition" ] && link="$cf_link"
      rows+="| \`$agent\` | $state | \`$disp_tr\` | ${cum_fail:-0} | ${triage:--} | $link |"$'\n'
      rendered=1
    done <<< "$pairs_out"
    [ "$rendered" -eq 0 ] && rows+="| \`$agent\` | COMPLETE | \`-\` | 0 | - | — |"$'\n'
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
  # Fail closed (#820): if any agent's state was totally undeterminable this tick, end non-zero
  # AFTER rendering the dashboard — a green no-op would mask a possible regression.
  [ "$hard_fail" -eq 1 ] && return 1
  return 0
}

# ── promotion tag-write failure escalation (durable trend + blocker, #1023 defect 2) ──
# A gate-BLOCKED promotion is expected and already tracked (canary-blocker). A FAILED tag WRITE
# (permission/API rejection on the move) is UNEXPECTED and, before #1023, left only a scrolling
# run-log line — no durable artifact, no trend. This turns each run's failed writes (recorded in
# CANARY_PROMOTIONS_FAILED_LOG by cmd_promote) into a per-agent tracking issue whose CONSECUTIVE-
# failure streak escalates to needs-human + dev-lead at CANARY_PROMOTION_FAILURE_ESCALATE_AFTER
# runs — and auto-closes the moment a write succeeds (agent in the CANARY_PROMOTIONS_LOG success
# log). Best-effort GitHub writes; never aborts the run.

# _promo_log_agents <tsv_file> — unique agent (column 1) values in a promotions log, one per line;
# empty when the path is unset or the file is missing/empty.
_promo_log_agents() {
  local f="$1"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  cut -f1 "$f" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# _promo_fail_latest <agent> — the LAST failure-log line's "ring<TAB>cand<TAB>host<TAB>reason" for
# <agent> (the most recent failure this run), empty if none.
_promo_fail_latest() {
  local agent="$1" f="${CANARY_PROMOTIONS_FAILED_LOG:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  awk -F'\t' -v a="$agent" '$1==a{ r=$2"\t"$3"\t"$4"\t"$5 } END{ if (r!="") print r }' "$f"
}

# _promo_fail_body <agent> <count> <threshold> <ring> <cand> <host> <reason> <escalated:0|1>
_promo_fail_body() {
  local agent="$1" count="$2" threshold="$3" ring="$4" cand="$5" host="$6" reason="$7" escalated="$8" note
  if [ "$escalated" = 1 ]; then
    note="> ⛔ **ESCALATED (needs-human).** This tag write has failed on **$count consecutive** scheduled runs (threshold $threshold) — it is not self-healing. Unlike a gate block (expected, timer-cleared), a failing WRITE means the move itself is rejected: check the release-manager App's ruleset bypass + token scopes for \`$ring\` on \`$host\`, then re-run \`promote $agent\`. This issue auto-closes on the next successful promotion."
  else
    note="> ℹ️ **Tracking a failed tag write.** The promotion move for \`$agent\` was rejected this run (not a gate block — the gate would hold *before* the write). Consecutive failures: **$count** of $threshold before escalation to \`needs-human\`. Auto-closes on the next successful promotion."
  fi
  cat <<EOF
<!-- canary-promo-fail:$agent -->
<!-- canary-promo-fail-count:$count -->
**Automated canary-rollout promotion-failure tracker.** A tag WRITE (not a gate decision) is failing for \`$agent\`. Filed + maintained by the Canary Rollout workflow; regenerated each run and **auto-closes** when a promotion succeeds — do not edit by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| ring | \`$ring\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| consecutive failing runs | **$count** (escalates at $threshold) |
| latest reason | ${reason:-tag write rejected} |

$note
---
_Distinct from a gate-blocked promotion (tracked by \`canary-blocker\`): this is an unexpected write rejection, tracked so it escalates rather than scrolling past._
EOF
}

# cmd_sync_promotion_failures [--dry-run] — reconcile this run's failed tag writes into durable,
# escalating tracking issues (see section header). Reads CANARY_PROMOTIONS_FAILED_LOG (failures)
# and CANARY_PROMOTIONS_LOG (successes); an agent present in neither was not attempted this run
# and is left untouched. Reads ISSUE_REPO (default THIS_REPO).
cmd_sync_promotion_failures() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  local threshold="${CANARY_PROMOTION_FAILURE_ESCALATE_AFTER:-2}"
  case "$threshold" in ''|*[!0-9]*) threshold=2 ;; esac
  [ "$threshold" -lt 1 ] && threshold=1
  echo "== canary-rollout sync-promotion-failures: repo=$ISSUE_REPO dry=$dry threshold=$threshold =="
  local failed_agents ok_agents attempted
  failed_agents="$(_promo_log_agents "${CANARY_PROMOTIONS_FAILED_LOG:-}")"
  ok_agents="$(_promo_log_agents "${CANARY_PROMOTIONS_LOG:-}")"
  attempted="$(printf '%s\n%s\n' "$failed_agents" "$ok_agents" | awk 'NF && !seen[$0]++')"
  if [ -z "$attempted" ]; then
    echo "  no promotion attempts recorded this run — nothing to reconcile."; return 0
  fi
  if [ "$dry" != true ]; then
    gh label create canary-promotion-failure --repo "$ISSUE_REPO" --color b60205 --description "canary-rollout: a promotion tag WRITE is failing (not a gate block)" >/dev/null 2>&1 || true
    gh label create dev-lead --repo "$ISSUE_REPO" --color 5319e7 --description "Route to the dev-lead agent for action" >/dev/null 2>&1 || true
    gh label create needs-human --repo "$ISSUE_REPO" --color d93f0b --description "Requires human judgement (canary regression)" >/dev/null 2>&1 || true
  fi
  local issues_json
  if ! issues_json="$(gh issue list --repo "$ISSUE_REPO" --label canary-promotion-failure --state all -L 100 --json number,state,body 2>/dev/null)"; then
    echo "::error::could not list canary-promotion-failure issues on $ISSUE_REPO — aborting to avoid creating duplicate tracking issues." >&2
    return 1
  fi
  # A successful write cancels a failure only for the SAME ring: one run can now advance several
  # rings (#1118), so a ring0 success must not hide a ring1 failure for the same agent.
  local -A ok_ring=()
  if [ -n "${CANARY_PROMOTIONS_LOG:-}" ] && [ -s "$CANARY_PROMOTIONS_LOG" ]; then
    local ok_a ok_r
    while IFS=$'\t' read -r ok_a ok_r _; do
      [ -n "$ok_a" ] && ok_ring["$ok_a|$ok_r"]=1
    done < "$CANARY_PROMOTIONS_LOG"
  fi
  local -A promo_failures=() unresolved=()
  local _pf_agent _pf_num _pf_state _pf_count
  while IFS=$'\t' read -r _pf_agent _pf_num _pf_state _pf_count; do
    [ -n "$_pf_agent" ] && promo_failures["$_pf_agent"]="${_pf_num}"$'\t'"${_pf_state}"$'\t'"${_pf_count}"
  done < <(printf '%s\n' "$issues_json" | jq -r '(sort_by(.number) // []) | .[]? | select(.body != null) | (try (.body | capture("<!-- canary-promo-fail:(?<agent>[^ ]+) -->")) catch null) as $c | select($c != null) | ([.body | match("canary-promo-fail-count:([0-9]+)") | .captures[0].string] | first // "0") as $count | "\($c.agent)\t\(.number)\t\(.state | ascii_upcase)\t\($count)"' 2>/dev/null)
  # Parse the failure log once before the per-agent loop to avoid spawning awk on every iteration.
  local -A fail_ring=() fail_cand=() fail_host=() fail_reason=()
  if [ -n "${CANARY_PROMOTIONS_FAILED_LOG:-}" ] && [ -s "$CANARY_PROMOTIONS_FAILED_LOG" ]; then
    local lf_agent lf_ring lf_cand lf_host lf_reason
    while IFS=$'\t' read -r lf_agent lf_ring lf_cand lf_host lf_reason; do
      if [ -n "$lf_agent" ]; then
        # Superseded by a successful write of the same ring this run (a retry) → not a failure.
        [ -n "${ok_ring["$lf_agent|$lf_ring"]:-}" ] && continue
        unresolved["$lf_agent"]=1
        fail_ring["$lf_agent"]="$lf_ring"
        fail_cand["$lf_agent"]="$lf_cand"
        fail_host["$lf_agent"]="$lf_host"
        fail_reason["$lf_agent"]="$lf_reason"
      fi
    done < "$CANARY_PROMOTIONS_FAILED_LOG"
  fi
  local agent
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    local outcome="ok"
    [ -n "${unresolved["$agent"]:-}" ] && outcome="failed"
    local ns num istate prior
    ns="${promo_failures["$agent"]:-}"
    num="$(printf '%s' "$ns" | cut -f1)"; istate="$(printf '%s' "$ns" | cut -f2)"; prior="$(printf '%s' "$ns" | cut -f3)"
    [ -z "$prior" ] && prior=0
    # A CLOSED tracking issue means the streak already ended; its stale count must not seed the
    # next streak or one transient failure would escalate on its first occurrence after recovery.
    [ "$istate" = "CLOSED" ] && prior=0
    local count; count="$(promotion_failure_next_count "$prior" "$outcome")"
    if [ "$outcome" = "failed" ]; then
      local ring cand host reason escalate body title
      ring="${fail_ring["$agent"]:-?}"
      cand="${fail_cand["$agent"]:-}"
      host="${fail_host["$agent"]:-?}"
      reason="${fail_reason["$agent"]:-tag write rejected}"
      escalate="$(promotion_failure_should_escalate "$count" "$threshold")"
      body="$(_promo_fail_body "$agent" "$count" "$threshold" "$ring" "$cand" "$host" "$reason" "$escalate")"
      if [ "$escalate" = 1 ]; then
        title="Canary promotion FAILING: $agent (${count}× consecutive tag-write rejection)"
      else
        title="Canary promotion tag-write failed: $agent (${count}× consecutive)"
      fi
      if [ -z "$num" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN promotion-failure issue for $agent (count=$count, escalate=$escalate)"; else
          num="$(_gh_issue_create "$title" "$body" "canary-promotion-failure" || true)"
          if [ -n "$num" ]; then
            [ "$escalate" = 1 ] && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened promotion-failure issue #$num for $agent (count=$count)"
          else echo "::warning::could not open promotion-failure issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE promotion-failure issue #$num for $agent (count=$count, escalate=$escalate)"; else
          [ "$istate" = "OPEN" ] || gh issue reopen "$num" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$num" --repo "$ISSUE_REPO" --title "$title" --body "$body" >/dev/null 2>&1 \
            || echo "::warning::could not update promotion-failure issue #$num for $agent"
          [ "$escalate" = 1 ] && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead --add-label needs-human >/dev/null 2>&1 || true
          echo "  updated promotion-failure issue #$num for $agent (count=$count)"
        fi
      fi
    else
      # A successful write this run resets the streak → close any open tracking issue.
      if [ -n "$num" ] && [ "$istate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE recovered promotion-failure issue #$num for $agent"; else
          gh issue close "$num" --repo "$ISSUE_REPO" \
            --comment "✅ Promotion succeeded — \`$agent\` tag write recovered. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed recovered promotion-failure issue #$num for $agent"
        fi
      fi
    fi
  done <<< "$attempted"
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

# ── watched agent_ref paths (#1019) ─────────────────────────────────────────────
# A consumer checks out MORE than the reusable at its pinned channel tag: the reusable checks
# out scripts/ (and prompts/, personas/) at `agent_ref`. Autocut/drift must therefore watch the
# whole agent_ref-consumed path set, not just the reusable blob. The set is DERIVED FROM THE
# REGISTRY (source of truth) — a top-level `agent_ref_paths` default with an optional per-agent
# `.agents[a].agent_ref_paths` override — falling back to this built-in only if the registry
# omits it entirely (defense-in-depth, never the primary source).
_DEFAULT_AGENT_REF_PATHS=$'scripts/\nprompts/\npersonas/'

# _watched_paths <agent> — newline list of host-relative paths a consumer EXECUTES at agent_ref:
# the registry `reusable` file plus the configured `agent_ref_paths` (per-agent override, else
# top-level default, else the built-in fallback). Deduped, blanks dropped.
_watched_paths() {
  local agent="$1" reusable extra
  reusable="$(_agent_field "$agent" reusable)"
  # Distinguish "the registry OMITS agent_ref_paths" (→ built-in fallback) from "the registry
  # sets it to []" (→ an intentional opt-out that must be honoured). Testing the rendered list
  # for emptiness conflates the two, so an agent that deliberately watches only its reusable
  # would silently get scripts/, prompts/ and personas/ back. Probe presence with `has` first.
  local declared
  declared="$(_jq -r --arg a "$agent" \
    'if (.agents[$a]? | type) == "object" and (.agents[$a] | has("agent_ref_paths")) then "agent"
     elif has("agent_ref_paths") then "top"
     else "none" end' 2>/dev/null || echo none)"
  extra="$(_jq -r --arg a "$agent" \
    '(.agents[$a].agent_ref_paths // .agent_ref_paths // []) | .[]?' 2>/dev/null || true)"
  [ -z "$extra" ] && [ "$declared" = "none" ] && extra="$_DEFAULT_AGENT_REF_PATHS"
  { [ -n "$reusable" ] && printf '%s\n' "$reusable"; printf '%s\n' "$extra"; } \
    | awk 'NF && !seen[$0]++'
}

# _gh_changed_files <repo> <base> <head> — filenames changed between <base>..<head> via the
# compare API (one per line; empty on error / no diff). Raw fetch + local jq (mirrors _run_json)
# so a test stub can serve the compare payload without re-implementing --jq.
#
# TRUNCATION (#1019): the compare API caps `.files` at 300 entries and sets
# `.truncated: true` when the range exceeds it. Reading `.files` alone would then
# silently OMIT changed paths — and since autocut ships a new version only when a
# WATCHED path changed, an omitted `scripts/…` entry means the cut is skipped and
# the change never reaches the fleet, with nothing red anywhere. That is exactly the
# silent-non-delivery failure this issue exists to remove, so the truncated case must
# never be treated as "no change". On truncation we fall back to enumerating each
# commit in the range (`.commits[].sha` → `repos/<repo>/commits/<sha>`) and union
# their file lists. Errors still degrade to empty (the caller treats empty as
# "unknown", not "unchanged").
_gh_changed_files() {
  local repo="$1" base="$2" head="$3" json truncated files
  { [ -z "$base" ] || [ -z "$head" ]; } && { echo ""; return 0; }
  json="$(gh api "repos/$repo/compare/$base...$head" 2>/dev/null)" || { echo ""; return 0; }
  [ -z "$json" ] && { echo ""; return 0; }

  truncated="$(jq -r '.truncated // false' <<< "$json" 2>/dev/null || echo false)"
  if [ "$truncated" != "true" ]; then
    jq -r '.files[]?.filename // empty' <<< "$json" 2>/dev/null || echo ""
    return 0
  fi

  # Truncated: union the per-commit file lists. Seed with whatever the compare DID
  # return so a per-commit fetch failure can only ever lose precision, not regress
  # below the un-truncated behaviour.
  files="$(jq -r '.files[]?.filename // empty' <<< "$json" 2>/dev/null || echo "")"
  local sha commit_json
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    commit_json="$(gh api "repos/$repo/commits/$sha" 2>/dev/null)" || continue
    [ -z "$commit_json" ] && continue
    files+=$'\n'"$(jq -r '.files[]?.filename // empty' <<< "$commit_json" 2>/dev/null || echo "")"
  done < <(jq -r '.commits[]?.sha // empty' <<< "$json" 2>/dev/null)

  printf '%s\n' "$files" | awk 'NF && !seen[$0]++'
}

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

# _autocut_bump_override <agent> — the EXPLICIT bump override for the agent (registry knob
# .agents[a].autocut.bump), or empty when unset/invalid. Since #712 the knob is an OVERRIDE
# over signal-based detection (not the sole source), so an absent/invalid knob yields empty
# (→ detection decides) rather than defaulting to patch.
_autocut_bump_override() {
  local b
  b="$(_jq -r --arg a "$1" '.agents[$a]?.autocut?.bump // ""')"
  case "$b" in major|minor|patch) echo "$b" ;; *) echo "" ;; esac
}

# _commit_date <host> <sha> — the committer (or author) date of <sha> on <host>, ISO-8601, empty
# on any error. Used to bound the range enumeration with a `since` window (see below).
_commit_date() {
  gh api "repos/$1/commits/$2" --jq '.commit.committer.date // .commit.author.date // empty' 2>/dev/null || echo ""
}

# _autocut_signal_paths <agent> — the repo paths whose commits carry release-bump signals for this
# agent, one per line, de-duplicated. ALWAYS includes the registry `reusable` path; extend it
# with the optional `.agents[a].autocut.watched_paths[]` knob (e.g. a shared library the reusable
# sources). Bump detection is scoped to commits touching THESE paths, so an unrelated commit
# elsewhere in the range never moves the bump (#1023 defect 1a): the classic failure was a
# `docs: feat!:` on an unrelated file forcing a spurious major that seeds a fresh `v<newMAJOR>-next`
# (#657 F4) and strands consumers pinned to the old major.
_autocut_signal_paths() {
  local agent="$1"
  { _agent_field "$agent" reusable
    _jq -r --arg a "$agent" '.agents[$a]?.autocut?.watched_paths? // [] | .[]?'
  } 2>/dev/null | awk 'NF && !seen[$0]++'
}

# _autocut_commit_signals <agent> <host> <next_commit> <mainsha> — scan the commits in
# (next_commit, mainsha] that TOUCH one of the agent's watched paths, echoing "<breaking 0|1>
# <feat 0|1>". breaking=1 iff any such commit is a conventional-commit `!` (`type(scope)!:`) or
# carries a `BREAKING CHANGE:`/`BREAKING-CHANGE:` footer; feat=1 iff any such commit subject is
# `feat:`/`feat(scope):` (non-breaking).
#
# Two defects this closes (#1023 defect 1):
#   • SCOPED — signals come only from `commits?path=<watched>` results (per watched path), so an
#     unrelated `feat!`/`BREAKING CHANGE` elsewhere in the range is invisible to the bump.
#   • ENUMERATED, not truncated — the range is PAGINATED (never a single capped response) and
#     bounded by a `since=<next_commit date>` window, so a breaking change beyond the first
#     page's cap is still seen. The boundary commit itself is EXCLUDED (its message predates the
#     range).
#
# Return codes drive the caller's fail-safe DIRECTION:
#   0  signals resolved            → echo "<b> <f>"
#   1  fetch/parse error (no data) → caller keeps the PATCH fail-safe (never auto-major on a
#                                    transient API failure; a real break can still be forced with
#                                    the .agents[a].autocut.bump knob)
#   3  range UNRESOLVABLE — could not be fully enumerated within CANARY_MAX_COMMIT_PAGES pages →
#                                    caller FAILS SAFE TO MAJOR, loudly: an unenumerable range
#                                    must not silently downgrade a breaking change to a patch
#                                    (#1023 defect 1b), the more dangerous direction.
_autocut_commit_signals() {
  local agent="$1" host="$2" next_commit="$3" mainsha="$4"
  local path page json acc="[]" truncated=0 path_done
  local since; since="$(_commit_date "$host" "$next_commit")"
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    page=1; path_done=0
    while [ "$page" -le "$CANARY_MAX_COMMIT_PAGES" ]; do
      local since_args=(); [ -n "$since" ] && since_args=(-f "since=$since")
      json="$(gh api --method GET "repos/$host/commits" -f path="$path" -f sha="$mainsha" "${since_args[@]}" -F per_page=100 -F page="$page" 2>/dev/null)" || return 1
      # Parse the page and extract found, count, and pre-boundary messages in a single jq invocation
      local parsed found count pre rest
      parsed="$(printf '%s\n' "$json" | jq -r --arg stop "$next_commit" '
        if type != "array" then error("not an array") else . end
        | (map(.sha)) as $shas
        | ([ range(0; length) | select($shas[.] == $stop) ] | first) as $idx
        | (any(.[]?; .sha == $stop) // false) as $found
        | "\($found)\t\(length)\t\(if $idx == null then . else .[0:$idx] end | map(.commit.message // "") | @json)"
      ' 2>/dev/null)" || return 1
      found="${parsed%%$'\t'*}"; rest="${parsed#*$'\t'}"; count="${rest%%$'\t'*}"; pre="${rest#*$'\t'}"
      acc="$(jq -cn --argjson a "$acc" --argjson b "$pre" '$a + $b' 2>/dev/null)" || return 1
      commit_page_done "$found" "${count:-0}" 100 || { path_done=1; break; }
      page=$((page + 1))
    done
    [ "$path_done" -eq 1 ] || truncated=1
  done <<< "$(_autocut_signal_paths "$agent")"
  [ "$truncated" -eq 1 ] && return 3
  [ "$acc" = "[]" ] && return 2
  local out
  out="$(printf '%s\n' "$acc" | jq -r '
    { b: any(.[]?; (. // "") | test("^[\\w-]+(\\([^)]*\\))?!:") or test("(^|\\n)BREAKING[ -]CHANGE:")),
      f: any(.[]?; (. // "") | test("^feat(\\([^)]*\\))?:")) }
    | "\(if .b then 1 else 0 end) \(if .f then 1 else 0 end)"
  ' 2>/dev/null)" || return 1
  [ -z "$out" ] && return 1
  printf '%s\n' "$out"
}

# _autocut_range_signals <host> <base> <head> — the conventional-commit signals over ALL commits
# between <base> and <head> (the compare range), echoing "<breaking 0|1> <feat 0|1>". Used as the
# fallback signal source when the reusable-path-scoped scan finds no boundary (a SCRIPT-ONLY
# change touches no reusable commit, #1019), so a script-only `feat`/`!`/`BREAKING CHANGE` still
# bumps correctly. Detection is byte-identical to _autocut_commit_signals; only the commit source
# differs (compare `.commits[]` — already correctly bounded, no boundary search). Returns non-zero
# on any fetch/parse error so the caller stays fail-safe to patch (never auto-major on missing data).
_autocut_range_signals() {
  local host="$1" base="$2" head="$3" json out
  { [ -z "$base" ] || [ -z "$head" ]; } && return 1
  json="$(gh api "repos/$host/compare/$base...$head" 2>/dev/null)" || return 1
  [ -z "$json" ] && return 1
  out="$(jq -r '
    if (.commits | type) != "array" then error("no commits array") else . end
    | (.commits | map(.commit.message // "")) as $msgs
    | {
        b: any($msgs[]; test("^\\w+(\\([^)]*\\))?!:") or test("(^|\\n)BREAKING[ -]CHANGE:")),
        f: any($msgs[]; test("^feat(\\([^)]*\\))?:"))
      }
    | "\(if .b then 1 else 0 end) \(if .f then 1 else 0 end)"
  ' <<< "$json" 2>/dev/null)" || return 1
  [ -z "$out" ] && return 1
  printf '%s\n' "$out"
}

# _gh_file_content <repo> <path> <ref> — the decoded text of <path> at <ref> on <repo> via the
# contents API (base64 → text). Non-zero on any fetch/decode error.
_gh_file_content() {
  local raw
  raw="$(gh api "repos/$1/contents/$2?ref=$3" --jq '.content // empty' 2>/dev/null)" || return 1
  [ -z "$raw" ] && return 1
  printf '%s' "$raw" | tr -d '\n' | base64 -d 2>/dev/null || return 1
}

# _autocut_iface_break <host> <reusable> <next_commit> <mainsha> — echo 1 if the reusable's
# `on.workflow_call` interface has a BREAKING change (removed/renamed input|secret, or a
# newly-required input) between the `next` candidate and main HEAD, else 0. Non-zero return on
# any fetch error so the caller does not escalate to major on missing interface data.
_autocut_iface_break() {
  local host="$1" reusable="$2" old_ref="$3" new_ref="$4" old_c new_c
  old_c="$(_gh_file_content "$host" "$reusable" "$old_ref")" || return 1
  new_c="$(_gh_file_content "$host" "$reusable" "$new_ref")" || return 1
  interface_break "$(workflow_call_iface "$old_c")" "$(workflow_call_iface "$new_c")"
}

# _autocut_detect_bump <agent> <host> <reusable> <next_commit> <mainsha> — the release bump for
# an autocut, echoed on stdout (a `::notice::` recording the level + driving signal goes to
# stderr so it does not pollute the captured value). The `.agents[a].autocut.bump` knob wins as
# an explicit override (even over a failed signal fetch); otherwise the level is DETECTED from
# the watched-path commit signals and the workflow_call interface diff via decide_bump. Fail-safe
# DIRECTION depends on WHY signals are missing (#1023 defect 1): a transient fetch error fails
# safe to PATCH (never auto-major on missing data — a real break can still be forced with the
# knob), but an UNRESOLVABLE range (too long to enumerate) fails safe to MAJOR, loudly — an
# unenumerable range must not silently downgrade a breaking change to a patch.
_autocut_detect_bump() {
  local agent="$1" host="$2" reusable="$3" next_commit="$4" mainsha="$5"
  local override; override="$(_autocut_bump_override "$agent")"
  if [ -n "$override" ]; then
    echo "::notice::autocut $agent: bump=$override (registry override .agents[$agent].autocut.bump)" >&2
    echo "$override"; return 0
  fi
  local breaking=0 feat=0 driver="" sigs iface rc=0
  sigs="$(_autocut_commit_signals "$agent" "$host" "$next_commit" "$mainsha")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    read -r breaking feat <<< "$sigs"
  elif [ "$rc" -eq 3 ]; then
    # Unresolvable range (#1023 defect 1b): the range could not be fully enumerated, so a
    # breaking change may hide beyond the cap. FAIL SAFE TO MAJOR, loudly — never silently to
    # patch, the more dangerous direction (a breaking change shipped as a patch breaks pinned
    # consumers with no signal). A false major is at worst a spurious fresh v-line + this warning.
    echo "::warning::autocut $agent: commit range ${next_commit:0:12}..${mainsha:0:12} on $host could not be fully enumerated within $CANARY_MAX_COMMIT_PAGES pages — cannot rule out a breaking change; failing safe to bump=major (not patch). Investigate the range." >&2
    breaking=1; feat=0; driver="unresolvable commit range (fail-safe major)"
  elif [ "$rc" -eq 2 ] && sigs="$(_autocut_range_signals "$host" "$next_commit" "$mainsha")"; then
    # Reusable-path-scoped signals unavailable (a script-only change touches no reusable commit,
    # so the boundary scan finds nothing — rc=2): fall back to the compare-range commit messages
    # so a script-only feat/breaking still bumps correctly (#1019). A fetch error (rc=1) falls
    # through to the patch fail-safe instead, preserving watched-path scoping under API failures.
    read -r breaking feat <<< "$sigs"
  else
    echo "::notice::autocut $agent: commit-signal fetch failed — bump=patch (fail-safe)" >&2
    echo "patch"; return 0
  fi
  [ "$breaking" = 1 ] && [ -z "$driver" ] && driver="conventional-commit breaking change"
  # An interface break escalates to major; a fetch error here is non-fatal (keep commit signals)
  # and never invents a major from missing data.
  if iface="$(_autocut_iface_break "$host" "$reusable" "$next_commit" "$mainsha")"; then
    if [ "$iface" = 1 ]; then breaking=1; driver="workflow_call interface break"; fi
  fi
  local bump; bump="$(decide_bump "$breaking" "$feat" "")"
  if [ -z "$driver" ]; then
    case "$bump" in
      minor) driver="feat commit" ;;
      *)     driver="no breaking/feat signal" ;;
    esac
  fi
  echo "::notice::autocut $agent: detected bump=$bump ($driver)" >&2
  echo "$bump"
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
  # Fast no-op: main HEAD already IS the current candidate — nothing merged since the last cut.
  if [ "$mainsha" = "$next_commit" ]; then
    echo "autocut $agent: reusable unchanged on $host (next candidate up to date) — no cut."
    return 0
  fi
  # Decide whether anything a consumer EXECUTES at agent_ref changed between the current `next`
  # candidate and main HEAD (#1019). Previously autocut compared ONLY the reusable FILE blob, so a
  # script-only change — scripts/, prompts/, personas/, what the reusable checks out at agent_ref —
  # shipped NOWHERE (no cut, no soak, no promotion). Detection now covers the reusable blob (the
  # fast path, kept byte-identical for a reusable change) OR any other registry-derived watched
  # path (via the compare API).
  local reusable_changed=0
  if [ -z "$next_commit" ] || [ -z "$next_blob" ]; then
    # Cannot compare the reusable blob (no candidate yet, or reusable absent at the candidate):
    # fail OPEN so a first cut / an unresolved candidate still seeds the pipeline (prior behaviour).
    reusable_changed=1
  elif [ "$main_blob" != "$next_blob" ]; then
    reusable_changed=1
  fi
  local watched_changed=0 watched_hitlist=""
  if [ "$reusable_changed" -eq 0 ] && [ -n "$next_commit" ]; then
    local watched changed_files
    watched="$(_watched_paths "$agent")"
    changed_files="$(_gh_changed_files "$host" "$next_commit" "$mainsha")"
    watched_hitlist="$(watched_hits "$changed_files" "$watched")"
    [ -n "$watched_hitlist" ] && watched_changed=1
  fi
  if [ "$reusable_changed" -eq 0 ] && [ "$watched_changed" -eq 0 ]; then
    echo "autocut $agent: no agent_ref-consumed path changed on $host (reusable + scripts/prompts/personas up to date) — no cut."
    return 0
  fi
  bump="$(_autocut_detect_bump "$agent" "$host" "$reusable" "$next_commit" "$mainsha")"
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

# _gh_list_reusables <repo> [registered_paths] — the full paths of reusable workflow files
# under the repo's .github/workflows (one per line). Reads the directory listing via the
# contents API and filters locally (mirrors _run_json: raw fetch, jq in the caller). Returns
# non-zero when the listing could NOT be enumerated (the API errored or did not return a JSON
# array), so the caller can distinguish "no reusables here" from "could not read the host" —
# the latter must NOT be treated as every registered reusable having been deleted (a false
# missing-file avalanche). A genuinely empty (but readable) workflows dir returns success
# with no output.
#
# A reusable is normally named `*-reusable.yml`. The optional newline-separated
# `registered_paths` (the registry's reusable paths for this host) ALSO admits a present file
# whose name is grandfathered off that convention — e.g. `pr-review.yml`, the pr-review engine
# kept on its legacy name until #1127 — so drift does not false-flag a legitimately-registered,
# actually-present reusable as `missing-file` (petry-projects/.github#1166). Both branches
# require the file to be present in the host listing, so a genuinely-deleted registered
# reusable (registered but NOT in the listing) is still reported missing.
_gh_list_reusables() {
  local repo="$1" registered="${2:-}" json=""
  # Strip CRs so a CRLF-terminated registered path still string-matches a host path (jq
  # splits on "\n" and a trailing "\r" would make every comparison miss).
  registered="${registered//$'\r'/}"
  json="$(gh api "repos/$repo/contents/.github/workflows" 2>/dev/null)" || return 1
  # An empty (but exit-0) body is not a readable listing — treat it as an enumeration
  # failure so the caller skips the host rather than false-flagging every reusable gone.
  [ -n "$json" ] || return 1
  jq -e 'type=="array"' >/dev/null 2>&1 <<< "$json" || return 1
  # The array type is validated above, so iterate with `.[]` (not `.[]?`): the optional
  # operator would silently swallow an iteration error on a malformed element instead of
  # surfacing it. `any(...)` is the idiomatic membership test for the registered paths.
  jq -r --arg reg "$registered" '
    ($reg | split("\n") | map(select(length>0))) as $regpaths
    | [ .[] | select(.type=="file")
        | .path as $p
        | select(($p | endswith("-reusable.yml"))
                 or (($p | test("\\.ya?ml$")) and any($regpaths[]; . == $p)))
        | $p ] | .[]' 2>/dev/null <<< "$json" || true
  return 0
}

# _reserved_tag_namespaces — tag prefixes that carry `<name>/v<M>-<tier>` channel tags on an infra
# repo but are NOT canary-managed agents (e.g. `standards`, the standards-versioning release channel
# #1091). Read from the registry's optional `.reserved_tag_namespaces` list so the allowlist is data,
# not code, and the completeness sweep (#1106) never false-flags a non-agent namespace. One per line.
_reserved_tag_namespaces() {
  _jq -r '(.reserved_tag_namespaces // []) | .[]'
}

# _gh_list_channel_tag_agents <repo> — the distinct agent names that own a v-scoped channel tag
# `<name>/v<M>-<tier>` or the bare `<name>/<tier>` (tier = next|ring<N>|stable) on <repo>, one per line, sorted. This is the
# COMPLETENESS signal (#1106): a channel tag is the fingerprint of a deployed, release-managed
# agent, so any name here that is absent from the registry is deployed-but-unmanaged. Same
# enumerate-or-fail contract as _gh_list_reusables — non-zero when the tag listing could NOT be
# read, so the caller does not mistake an API outage for "no channel tags". A release tag
# `<name>/vX.Y.Z` is not a channel tag and is ignored.
_gh_list_channel_tag_agents() {
  local repo="$1" json
  json="$(gh api "repos/$repo/git/matching-refs/tags" --paginate 2>/dev/null)" || return 1
  jq -e 'type=="array"' >/dev/null 2>&1 <<< "$json" || return 1
  jq -r '.[]? | .ref // empty' 2>/dev/null <<< "$json" \
    | sed -n -E 's#^refs/tags/(.+)/(v[0-9]+-)?(next|ring[0-9]+|stable)$#\1#p' \
    | sort -u
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

# _channel_tag_major_gaps <agent> — for an agent that has an ESTABLISHED channel major, echo one
# tier per line whose BARE channel tag `<agent>/<tier>` exists but whose v-scoped counterpart
# `<agent>/v<M>-<tier>` does NOT (the #1065 AC3 drift class). Empty for the legacy bare-only fleet
# (no channel major) — such an agent legitimately carries only bare tier tags. This is exactly the
# gap the promotion bootstrap trap (AC1′) could leave: a stub deploy keys the pin on the channel
# major and would pin a nonexistent `<agent>/v<M>-<tier>`, a fleet-wide startup_failure.
_channel_tag_major_gaps() {
  local agent="$1" major tier channels
  major="$(_agent_current_channel_major "$agent")"
  _agent_has_channel_major "$agent" "$major" || return 0
  channels="$(ordered_channels "$agent")"
  for tier in ${channels//,/ }; do
    [ -z "$tier" ] && continue
    [ -n "$(_channel_tag_commit "$agent" "$tier")" ] || continue          # no bare tier tag → nothing to pair
    [ -z "$(_channel_tag_commit "$agent" "v${major}-${tier}")" ] && printf '%s\n' "$tier"
  done
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
    registered="$(_registered_reusables_for_host "$host")"
    # Pass the registered paths so a present-but-grandfathered-named reusable (e.g.
    # pr-review.yml, #1127/#1166) is recognised as present rather than false-flagged
    # missing-file. A genuinely-deleted registered reusable is still absent from the
    # listing and so still reported.
    if ! present="$(_gh_list_reusables "$host" "$registered")"; then
      # Could not read the host's workflows dir — skip it rather than false-flag every
      # registered reusable as missing-file. Read-only + best-effort: a warning, not a failure.
      echo "::warning::drift $host: could not enumerate .github/workflows (API error / no access) — skipping host this cycle"
      continue
    fi
    unmanaged_r="$(_unmanaged_reusables_for_host "$host")"
    local reg_arr=() pres_arr=() um_arr=() reg_str="" pres_str="" um_str=""
    if [ -n "$registered" ]; then mapfile -t reg_arr <<< "$registered"; fi
    if [ -n "$present" ]; then mapfile -t pres_arr <<< "$present"; fi
    if [ -n "$unmanaged_r" ]; then mapfile -t um_arr <<< "$unmanaged_r"; fi
    [ "${#reg_arr[@]}" -gt 0 ] && reg_str=" ${reg_arr[*]}"
    [ "${#pres_arr[@]}" -gt 0 ] && pres_str=" ${pres_arr[*]}"
    [ "${#um_arr[@]}" -gt 0 ] && um_str=" ${um_arr[*]}"
    echo "  registered reusables (${#reg_arr[@]}):$reg_str"
    echo "  present reusables (${#pres_arr[@]}):$pres_str"
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
    # missing-file = registered in the registry but the file is gone from the host. A registered reusable
    # that keeps a legacy non-`-reusable.yml` name (the grandfathered pr-review.yml engine, #1166) is
    # recognised as present by _gh_list_reusables (which filters to include registered paths), so it is
    # correctly not flagged as missing.
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

  # ── per-agent "merged but not shipped" (#1019) ────────────────────────────────
  # For each registered agent, compare the `next` channel commit against host main HEAD across
  # the agent_ref-consumed paths. A non-empty diff means a change merged to host main that the
  # pinned channel has NOT yet shipped — the exact failure mode where a PR merges, CI stays
  # green, the issue closes, and the change reaches nobody. autocut should self-heal this on the
  # next tick; the report makes any lag visible without a hand-run `git diff`.
  echo "----"
  echo "== agent_ref ship-drift: next channel vs host main (agent_ref-consumed paths) =="
  local agents a unshipped_total=0 ship_rows=""
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    local a_host a_defbranch a_main a_next hits hitcsv h changed_files watched
    a_host="$(_agent_field "$a" host)"; a_host="${a_host:-$THIS_REPO}"
    a_next="$(channel_commit "$a" next)"
    a_defbranch="$(_gh_default_branch "$a_host")"; [ -z "$a_defbranch" ] && a_defbranch="main"
    a_main="$(_gh_head_sha "$a_host" "$a_defbranch")"
    if [ -z "$a_next" ] || [ -z "$a_main" ]; then
      echo "  $a: could not resolve next/main HEAD on $a_host — skipping"
      continue
    fi
    if [ "$a_next" = "$a_main" ]; then
      echo "  $a: shipped — next (${a_next:0:12}) == $a_host main HEAD"
      continue
    fi
    watched="$(_watched_paths "$a")"
    changed_files="$(_gh_changed_files "$a_host" "$a_next" "$a_main")"
    hits="$(watched_hits "$changed_files" "$watched")"
    if [ -z "$hits" ]; then
      echo "  $a: shipped — next differs from main but no agent_ref-consumed path changed"
      continue
    fi
    hitcsv=""
    while IFS= read -r h; do [ -z "$h" ] && continue; hitcsv="${hitcsv:+$hitcsv, }$h"; done <<< "$hits"
    echo "::warning::DRIFT[unshipped] $a: $a_host main (${a_main:0:12}) has agent_ref changes not on next (${a_next:0:12}): $hitcsv"
    ship_rows+="| \`$a\` | \`$a_host\` | \`$hitcsv\` | merged to main but not on the \`next\` channel (autocut should cut) |"$'\n'
    unshipped_total=$((unshipped_total + 1))
  done <<< "$agents"
  echo "ship-drift summary: $unshipped_total agent(s) with merged-but-unshipped agent_ref changes"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$unshipped_total" -gt 0 ]; then
    local smd
    smd="$(printf '# Canary Rollout — ship-drift (merged but not shipped)\n\nLast updated: `%s` · %s agent(s) whose `next` channel lags host main across agent_ref-consumed paths.\n\n| agent | host | changed paths | note |\n|---|---|---|---|\n%s\n> autocut (#1069) should cut a new candidate on the next tick; a persistent row means autocut is disabled or blocked.\n' "$ts" "$unshipped_total" "${ship_rows%$'\n'}")"
    printf '\n%s\n' "$smd" >> "$GITHUB_STEP_SUMMARY" \
      || echo "::warning::could not write the ship-drift job summary"
  fi

  # ── channel-tag drift: a bare tier tag lacking its v<M>-<tier> counterpart (#1065 AC3) ──
  # For every agent with an established channel major, a bare `<agent>/<tier>` must have its
  # v-scoped `<agent>/v<M>-<tier>` counterpart. The promotion bootstrap trap (AC1′) could strand
  # the v-line at whatever tier it was first seeded at, leaving a bare-only tier that resolution
  # silently masked but a stub deploy — which keys the pin on the channel major — would pin to a
  # NONEXISTENT ref, a fleet-wide startup_failure. This sweep surfaces the gap in one read-only
  # pass so it never again needs a hand-run audit. Backfilling the missing tag is a maintainer
  # action (it creates a channel tag); drift only reports.
  echo "----"
  echo "== channel-tag drift: bare tier tag without its v<M>-<tier> counterpart (#1065) =="
  local ct_agent ct_major ct_gaps ct_tier ct_total=0 ct_rows=""
  while IFS= read -r ct_agent; do
    [ -z "$ct_agent" ] && continue
    ct_major="$(_agent_current_channel_major "$ct_agent")"
    ct_gaps="$(_channel_tag_major_gaps "$ct_agent")"
    [ -z "$ct_gaps" ] && continue
    for ct_tier in $ct_gaps; do
      [ -z "$ct_tier" ] && continue
      echo "::warning::DRIFT[channel-tag] $ct_agent: has /$ct_tier but NO v${ct_major}-$ct_tier (a stub deploy to this tier would pin a nonexistent @$ct_agent/v${ct_major}-$ct_tier)"
      ct_rows+="| \`$ct_agent\` | \`$ct_tier\` | \`$ct_agent/v${ct_major}-$ct_tier\` | bare tier tag exists but its v-scoped counterpart is missing — a stub deploy pins a nonexistent ref (maintainer backfill) |"$'\n'
      ct_total=$((ct_total + 1))
    done
  done <<< "$agents"
  echo "channel-tag drift summary: $ct_total tier(s) missing a v<M>-<tier> counterpart"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$ct_total" -gt 0 ]; then
    local ctmd
    ctmd="$(printf '# Canary Rollout — channel-tag drift (missing v<M>-<tier>)\n\nLast updated: `%s` · %s tier(s) with a bare channel tag lacking its v-scoped counterpart.\n\n| agent | tier | missing ref | note |\n|---|---|---|---|\n%s\n> A ring-promotion bootstrap gap (#1065). A stub deploy keyed on the channel major pins `<agent>/v<M>-<tier>`; if it does not exist the fleet fails at startup. A maintainer backfills the tag at its bare counterpart'"'"'s commit.\n' "$ts" "$ct_total" "${ct_rows%$'\n'}")"
    printf '\n%s\n' "$ctmd" >> "$GITHUB_STEP_SUMMARY" \
      || echo "::warning::could not write the channel-tag drift job summary"
  fi

  # ── registry completeness: a channel-tag agent absent from the registry (#1106) ──────────────
  # Registry SELF-CONSISTENCY (RING_REUSABLES == .agents == the dispatch enum) is enforced by unit
  # tests, but it says nothing about COMPLETENESS: an agent can be fully deployed — carrying
  # <agent>/v<M>-<tier> channel tags on its host — yet be MISSING from .agents{}, so nothing cuts,
  # soaks, gates, or ships it. That is exactly how pr-review ran an 82-day-old build unnoticed
  # (#1106): the *-reusable.yml scan above never saw it (its engine keeps the legacy pr-review.yml
  # name) and every self-consistency test passed because the three registers agreed with each other.
  # This sweep inventories the channel tags on BOTH infra repos (tags live in the agent's host repo)
  # and flags any channel-tag agent that has no registry entry, excluding reserved non-agent
  # namespaces (e.g. `standards`, the standards-versioning channel #1091). Report-only — registering
  # needs human intent (ring topology/members); the check just makes the gap impossible to miss.
  echo "----"
  echo "== registry completeness: channel-tag agent absent from the registry (#1106) =="
  local infra_repos ir reserved registered_agents rc_total=0 rc_rows="" rc_seen="" rc_incomplete=0 rc_registry_empty=0 max_attempts=3
  infra_repos="$(_jq -r '(.org_infra_repos // []) | .[]')"
  reserved="$(_reserved_tag_namespaces)"
  registered_agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  if [ -z "$registered_agents" ]; then
    # An unreadable/empty registry would flag EVERY channel-tagged agent as unregistered (false
    # positives) — skip the sweep and mark it incomplete rather than report noise.
    echo "::warning::registry completeness: .agents{} is empty or unreadable — skipping the sweep"
    rc_incomplete=1
    rc_registry_empty=1
    infra_repos=""
  fi
  while IFS= read -r ir; do
    [ -z "$ir" ] && continue
    local tag_agents ta attempt
    attempt=0
    # Bounded retries for the tag enumeration: transient API failures should not silently miss
    # completeness gaps. After exhaustion, skip the repo but track that completeness was incomplete.
    while [ "$attempt" -lt "$max_attempts" ]; do
      if tag_agents="$(_gh_list_channel_tag_agents "$ir")"; then
        break
      fi
      attempt=$((attempt + 1))
      if [ "$attempt" -lt "$max_attempts" ]; then
        echo "::notice::completeness $ir: tag enumeration failed (attempt $attempt/$max_attempts), retrying..."
        sleep 2
      fi
    done
    if [ "$attempt" -eq "$max_attempts" ]; then
      # Could not read the repo's tags after retries — skip it rather than mistake an outage for "no channel
      # tags" (which would silently miss a real completeness gap). Read-only + best-effort, but track incomplete.
      echo "::warning::completeness $ir: could not enumerate channel tags after $max_attempts attempts (API error / no access) — skipping repo this cycle"
      rc_incomplete=1
      continue
    fi
    while IFS= read -r ta; do
      [ -z "$ta" ] && continue
      grep -qxF "$ta" <<< "$registered_agents" && continue           # registered → managed, fine
      grep -qxF "$ta" <<< "$reserved" && continue                    # reserved non-agent namespace
      grep -qxF "$ta" <<< "$rc_seen" && continue                     # already reported (tags on both repos)
      rc_seen+="$ta"$'\n'
      echo "::warning::DRIFT[registry-incomplete] $ir: '$ta' has <agent>/v*-<tier> channel tags but is NOT in canary-rings.json (.agents) — deployed but unmanaged (no cut/soak/gate/dashboard)"
      rc_rows+="| \`$ta\` | \`$ir\` | channel-tagged but absent from \`.agents{}\` — register it (or add to \`reserved_tag_namespaces\` if it is not an agent) |"$'\n'
      rc_total=$((rc_total + 1))
    done <<< "$tag_agents"
  done <<< "$infra_repos"
  if [ "$rc_incomplete" -eq 1 ]; then
    echo "registry-completeness summary: $rc_total agent(s) missing from registry; completeness check was INCOMPLETE (some repos could not be enumerated)"
  else
    echo "registry-completeness summary: $rc_total channel-tag agent(s) missing from the registry"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ "$rc_total" -gt 0 ]; then
      local rcmd
      rcmd="$(printf '# Canary Rollout — registry completeness (channel-tagged but unregistered)\n\nLast updated: `%s` · %s channel-tag agent(s) with `<agent>/v*-<tier>` tags on an infra repo but no `.agents{}` entry.\n\n| agent | host | note |\n|---|---|---|\n%s\n> Registry self-consistency is not completeness (#1106). A channel-tagged agent absent from the registry ships with ZERO staged rollout — no cut/soak/gate/dashboard — exactly how pr-review ran an 82-day-old build unnoticed. Register it, or add a genuine non-agent namespace to `reserved_tag_namespaces`.\n' "$ts" "$rc_total" "${rc_rows%$'\n'}")"
      printf '\n%s\n' "$rcmd" >> "$GITHUB_STEP_SUMMARY" \
        || echo "::warning::could not write the registry-completeness job summary"
    fi
    if [ "$rc_registry_empty" -eq 1 ]; then
      printf '\n> ⚠️ **Note:** Completeness sweep was skipped — the registry `.agents{}` is empty or unreadable, so no channel-tag agent could be checked. Fix the registry and re-run the check.\n' >> "$GITHUB_STEP_SUMMARY" \
        || echo "::warning::could not write the completeness-skipped notice"
    elif [ "$rc_incomplete" -eq 1 ]; then
      printf '\n> ⚠️ **Note:** Completeness check was incomplete — one or more infra repos could not be enumerated after %s attempts (API errors or access issues). Some deployed agents may not have been detected. Investigate and re-run the check.\n' "$max_attempts" >> "$GITHUB_STEP_SUMMARY" \
        || echo "::warning::could not write the completeness-incomplete notice"
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
  # Per-process run-list cache shared across the fan-out's command-substitution subshells
  # (#819) — exported so subshells inherit the path, and reaped on exit. This trap lives in
  # the PARENT shell; _repo_wf_runs_cached's errfile trap lives in the per-call subshells, so
  # the two are in different shells and never clobber each other.
  # The timing report runs on exit either way; only a directory main created is removed.
  local _own_cache=0
  if [ -z "${_RUNS_CACHE_DIR:-}" ]; then
    _RUNS_CACHE_DIR="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$_RUNS_CACHE_DIR" ]; then
      export _RUNS_CACHE_DIR
      _own_cache=1
    fi
  fi
  _CANARY_OWN_CACHE="$_own_cache"
  trap '_timing_report; rm -f "${_TIMING_LOG:-}" "${_TIMING_CALLS:-}"; [ "${_CANARY_OWN_CACHE:-0}" = 1 ] && rm -rf "${_RUNS_CACHE_DIR:-}"' EXIT
  # Load the registry lookups ONCE, here in the parent shell, so the fan-out's subshells inherit them
  # instead of re-parsing the registry per call (#1259). Failure just leaves the jq fallback in place.
  _registry_preload || true
  local sub="${1:-}"; shift || true
  _TIMING_SUB="$sub"; _timing_start || true
  case "$sub" in
    evaluate)     [ $# -ge 1 ] || { echo "usage: evaluate <agent>" >&2; return 2; }; cmd_evaluate "$@" ;;
    evaluate-all) cmd_evaluate_all ;;
    promote)      [ $# -ge 1 ] || { echo "usage: promote <agent> [--override] [--confirm] [--allow-pre-existing] [--dry-run]" >&2; return 2; }; cmd_promote "$@" ;;
    promote-all)  cmd_promote_all "$@" ;;
    rollback)     [ $# -ge 2 ] || { echo "usage: rollback <agent> <ring> --to <vX.Y.Z>" >&2; return 2; }; cmd_rollback "$@" ;;
    resolve)      [ $# -ge 2 ] || { echo "usage: resolve <agent> <channel>" >&2; return 2; }; resolve_members "$@" ;;
    sync-issues)  cmd_sync_issues "$@" ;;   # upsert blocker issues + dashboard for held promotions
    sync-promotion-failures) cmd_sync_promotion_failures "$@" ;;  # escalate failing tag writes into durable issues (#1023)
    autocut)      cmd_autocut "$@" ;;       # cut a new candidate when a reusable changes on main (#1069)
    drift)        cmd_drift "$@" ;;         # report reusables present on a host but unregistered, + stale registry entries (#1082)
    *) echo "::error::usage: canary-rollout.sh {autocut|drift|evaluate|evaluate-all|promote|promote-all|rollback|resolve|sync-issues|sync-promotion-failures} [args]" >&2; return 2 ;;
  esac
}

# Test hook: CANARY_PRELOAD_REGISTRY=1 preloads the registry lookups at source time, so the whole suite can
# be re-run against the memoized path (it must behave identically; see tests/canary_rollout.bats).
[ "${CANARY_PRELOAD_REGISTRY:-}" = "1" ] && { _registry_preload || true; }

# Source-guard: tests source this file to exercise resolve_members etc. without running.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
