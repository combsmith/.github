#!/usr/bin/env bash
set -euo pipefail
# standards-staleness.sh — staleness alarm for the standards release channel
# (issue #1173).
#
# Compares standards/ on the moving channel (standards/v<major>-stable) with the
# default branch and keeps ONE standing issue open while the gap is worth a
# promotion:
#   • a file under standards/workflows/ differs, or
#   • the oldest unpublished change to standards/ is more than
#     STANDARDS_STALENESS_MAX_DAYS days old.
# The issue lists the differing files. It is updated in place on each run and
# closed once the channel catches up. Nothing is promoted here: a human still
# decides when (standards/standards-versioning.md).
#
# The decision and the issue text live in the pure, unit-tested core
# scripts/lib/standards-staleness.sh; this file is thin gh glue.
#
# A fact that cannot be read fails the run. "Could not compare" is never
# reported as "fresh".
#
# Env:
#   SS_REPO     owner/name holding the standards tags
#               (default: $GITHUB_REPOSITORY, else petry-projects/.github).
#   SS_BRANCH   branch to compare the channel against (default: the repo's
#               default branch).
#   SS_CHANNEL  channel tag to check (default: the channel of the highest
#               published standards/vX.Y.Z).
#   STANDARDS_STALENESS_MAX_DAYS  age limit in days (default 7).
#   DRY_RUN     "true" → print what would be done; open, edit or close nothing.
#   GH_TOKEN    needs contents:read, and issues:write unless DRY_RUN=true.

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/standards-release.sh
source "${_HERE}/lib/standards-release.sh"
# shellcheck source=lib/standards-staleness.sh
source "${_HERE}/lib/standards-staleness.sh"

SS_REPO="${SS_REPO:-${GITHUB_REPOSITORY:-petry-projects/.github}}"
SS_MAX_DAYS="${STANDARDS_STALENESS_MAX_DAYS:-7}"
DRY_RUN="${DRY_RUN:-false}"

_fail() { echo "::error::$*" >&2; exit 1; }

# _current_channel — the channel of the highest published standards/vX.Y.Z on
# SS_REPO. Empty when nothing is published. Fails when the tags cannot be listed.
_current_channel() {
  local refs ref v highest
  local -a versions=()
  refs="$(gh api "repos/$SS_REPO/git/matching-refs/tags/standards/v" --jq '.[].ref')" \
    || _fail "could not list standards/* tags on $SS_REPO"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    v="$(sr_version_from_tag "${ref#refs/tags/}")"
    [ -n "$v" ] && versions+=("$v")
  done <<< "$refs"
  [ "${#versions[@]}" -gt 0 ] || return 0
  highest="$(sr_max_version "${versions[@]}")"
  [ -n "$highest" ] || return 0
  sr_channel_for "$highest"
}

# _commit_sha <ref> — the full commit SHA <ref> resolves to on SS_REPO (an
# annotated tag is dereferenced). Fails when it cannot be read: an error body is
# not a 40-hex SHA.
_commit_sha() {
  local sha
  sha="$(gh api -H "Accept: application/vnd.github.sha" "repos/$SS_REPO/commits/$1")" \
    || _fail "could not resolve $1 on $SS_REPO"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || _fail "could not resolve $1 on $SS_REPO to a commit"
  printf '%s' "$sha"
}

# _standards_tree_sha <commit_sha> — the git tree SHA of standards/ at that commit.
# Empty when the commit has no standards/ directory. Fails when the root tree
# cannot be read in full.
_standards_tree_sha() {
  local out
  out="$(gh api "repos/$SS_REPO/git/trees/$1")" || _fail "could not read the root tree at ${1:0:12} on $SS_REPO"
  jq -e '(.tree | type == "array") and (.truncated != true)' <<< "$out" > /dev/null \
    || _fail "the root tree at ${1:0:12} on $SS_REPO came back incomplete"
  jq -r '.tree[] | select(.path == "standards" and .type == "tree") | .sha' <<< "$out"
}

# _standards_blobs <tree_sha> — "<path>\t<blob sha>" for every file under the
# standards/ tree <tree_sha>, paths prefixed "standards/". Nothing for an empty
# <tree_sha>. Fails when the listing cannot be read in full, so a partial listing
# is never diffed as if it were complete.
_standards_blobs() {
  local out
  [ -n "${1:-}" ] || return 0
  out="$(gh api "repos/$SS_REPO/git/trees/$1?recursive=1")" || _fail "could not list standards/ at tree ${1:0:12} on $SS_REPO"
  jq -e '(.tree | type == "array") and (.truncated != true)' <<< "$out" > /dev/null \
    || _fail "the listing of standards/ at tree ${1:0:12} on $SS_REPO came back incomplete"
  jq -r '.tree[] | select(.type == "blob") | "standards/\(.path)\t\(.sha)"' <<< "$out"
}

# _alarm_issue <marker> — number of the open issue whose body carries <marker>,
# or empty. Uses the issue list, not search: search does not index HTML comments.
_alarm_issue() {
  local out
  out="$(gh issue list --repo "$SS_REPO" --state open --limit 500 --json number,body)" \
    || _fail "could not list open issues on $SS_REPO"
  jq -r --arg m "$1" '[.[] | select((.body // "") | contains($m)) | .number] | min // empty' <<< "$out"
}

main() {
  local cmd
  for cmd in gh jq; do
    command -v "$cmd" >/dev/null 2>&1 || _fail "$cmd is required"
  done
  [[ "$SS_MAX_DAYS" =~ ^[0-9]+$ ]] || _fail "STANDARDS_STALENESS_MAX_DAYS must be a whole number of days, got '$SS_MAX_DAYS'"

  local branch="${SS_BRANCH:-}" channel="${SS_CHANNEL:-}"
  if [ -z "$branch" ]; then
    branch="$(gh api "repos/$SS_REPO" --jq '.default_branch')" || _fail "could not read the default branch of $SS_REPO"
  fi
  if [ -z "$channel" ]; then
    channel="$(_current_channel)"
  fi
  if [ -z "$channel" ]; then
    echo "::notice::no standards/vX.Y.Z release is published on $SS_REPO yet — there is no channel to compare."
    return 0
  fi

  # Pin both ends to commits FIRST, then read everything else at those two SHAs,
  # so a branch that moves mid-run cannot pair one commit's diff with another's SHA.
  local channel_sha branch_sha
  channel_sha="$(_commit_sha "$channel")"
  branch_sha="$(_commit_sha "$branch")"

  local cmp channel_date ahead
  cmp="$(gh api "repos/$SS_REPO/compare/${channel_sha}...${branch_sha}")" \
    || _fail "could not compare $channel with $branch on $SS_REPO"
  channel_date="$(jq -r '.base_commit.commit.committer.date // empty' <<< "$cmp")"
  ahead="$(jq -r '.ahead_by // empty' <<< "$cmp")"
  [[ "$ahead" =~ ^[0-9]+$ && -n "$channel_date" && "$(jq -r '.base_commit.sha // empty' <<< "$cmp")" = "$channel_sha" ]] \
    || _fail "the compare of $channel with $branch on $SS_REPO came back without the expected fields"

  # The differing files come from the two git trees of standards/, not from the
  # compare response: compare lists at most 300 changed files for the whole repo,
  # so a standards change could be cut off and read as "no difference". Equal tree
  # SHAs mean standards/ is byte-identical, and nothing more is listed.
  local base_tree head_tree base_list head_list files="" n wf
  base_tree="$(_standards_tree_sha "$channel_sha")"
  head_tree="$(_standards_tree_sha "$branch_sha")"
  if [ "$base_tree" != "$head_tree" ]; then
    base_list="$(mktemp)"; head_list="$(mktemp)"
    _standards_blobs "$base_tree" > "$base_list"
    _standards_blobs "$head_tree" > "$head_list"
    files="$(ss_tree_diff "$base_list" "$head_list")" || { rm -f "$base_list" "$head_list"; _fail "could not diff the standards/ listings"; }
    rm -f "$base_list" "$head_list"
  fi
  n="$(printf '%s' "$files" | grep -c . || true)"
  wf="$(printf '%s\n' "$files" | cut -f2 | ss_workflow_files | grep -c . || true)"

  # Age of the oldest unpublished change: the oldest commit on the branch that
  # touched standards/ after the channel commit. If none is listed (the date
  # filter and the history disagree), fall back to the channel commit's own date.
  # The gap cannot be older than that, so it is a stated upper bound.
  local age="" bound=0 now oldest
  if [ "$n" -gt 0 ]; then
    now="$(date -u +%s)"
    oldest="$(gh api --paginate "repos/$SS_REPO/commits?sha=${branch_sha}&path=standards&since=${channel_date}&per_page=100" \
        --jq '.[] | [.sha, .commit.committer.date] | @tsv')" \
      || _fail "could not list the commits that changed standards/ on $branch since $channel_date"
    oldest="$(printf '%s\n' "$oldest" | awk -F'\t' -v base="$channel_sha" '$1 != "" && $1 != base { print $2 }' \
      | jq -Rr 'select(length > 0) | fromdateiso8601' | sort -n | head -n 1)"
    if [ -z "$oldest" ]; then
      oldest="$(jq -rn --arg d "$channel_date" '$d | fromdateiso8601')"
      bound=1
    fi
    age="$(ss_age_days "$now" "$oldest")" || _fail "could not compute the age of the oldest unpublished standards change"
  fi

  local decision
  decision="$(ss_decision "$n" "$wf" "${age:-0}" "$SS_MAX_DAYS")"
  echo "channel:  $channel -> ${channel_sha:0:12}"
  echo "branch:   $branch -> ${branch_sha:0:12} ($ahead commit(s) ahead)"
  echo "differs:  $n file(s) under standards/, $wf under standards/workflows/"
  [ -z "$age" ] || echo "oldest:   $age day(s)$([ "$bound" = "1" ] && echo ' (upper bound)') — limit $SS_MAX_DAYS"
  echo "decision: $decision"
  [ "$decision" != "UNKNOWN" ] || _fail "the staleness inputs could not be judged — not reporting the channel as fresh"

  local marker title existing body_file
  marker="$(ss_issue_marker "$channel")"
  title="$(ss_issue_title "$channel" "$branch")"
  existing="$(_alarm_issue "$marker")"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### Standards channel staleness\n\n'
      printf -- '- Channel: `%s` at `%s`\n- Branch: `%s` at `%s`, %s commit(s) ahead\n' \
        "$channel" "${channel_sha:0:12}" "$branch" "${branch_sha:0:12}" "$ahead"
      printf -- '- Differing `standards/` files: %s (%s under `standards/workflows/`)\n- Decision: **%s**\n' "$n" "$wf" "$decision"
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  case "$decision" in
    STALE*)
      body_file="$(mktemp)"
      printf '%s\n' "$files" | ss_issue_body "$channel" "$channel_sha" "$branch" "$branch_sha" "$ahead" \
        "$decision" "$age" "$SS_MAX_DAYS" "$bound" > "$body_file"
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] would $([ -n "$existing" ] && echo "update issue #$existing" || echo "open an issue"): $title"
        cat "$body_file"
      elif [ -n "$existing" ]; then
        gh issue edit "$existing" --repo "$SS_REPO" --title "$title" --body-file "$body_file" >/dev/null \
          || { rm -f "$body_file"; _fail "could not update alarm issue #$existing"; }
        echo "updated alarm issue #$existing"
      else
        gh issue create --repo "$SS_REPO" --title "$title" --body-file "$body_file" \
          || { rm -f "$body_file"; _fail "could not open the alarm issue"; }
      fi
      rm -f "$body_file"
      ;;
    *)
      if [ -z "$existing" ]; then
        echo "no alarm issue is open; nothing to do."
      elif [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] would close alarm issue #$existing ($decision)"
      else
        gh issue close "$existing" --repo "$SS_REPO" \
          --comment "\`$channel\` now points at \`${channel_sha:0:12}\` and the remaining gap to \`$branch\` is not worth an alarm (decision: $decision, $n differing \`standards/\` file(s)). Closing." >/dev/null \
          || _fail "could not close alarm issue #$existing"
        echo "closed alarm issue #$existing"
      fi
      ;;
  esac
}

main "$@"
