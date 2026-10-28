#!/usr/bin/env bash
# scripts/lib/standards-sync-provenance.sh — provenance gate for the
# standards-sync auto-approver (scripts/automerge-standards-sync.sh,
# combsmith/.github#1386).
#
# The approver posts a CODE-OWNER approval and enables auto-merge. The PR's
# label, head-branch name and author only say who OPENED it, not what is on the
# branch now: any repository writer can push to a `standards-sync/` branch after
# the deployer opens the PR. So before approving, the CURRENT head must still be
# a pure standards deploy:
#
#   ssp_check_commits  every commit on the PR is authored and committed by the
#                      deployer (a GitHub "Update branch" merge — committer
#                      web-flow, signature verified — is accepted when the
#                      deployer authored it), and the list ends at the head SHA.
#   ssp_check_pushes   every ref update GitHub recorded for the head branch
#                      (repository activity: push / force_push / creation) was
#                      made by the deployer, and the newest one is the head SHA.
#                      Commit author/committer emails can be forged; the pusher
#                      recorded by GitHub cannot.
#   ssp_check_files    every changed path is one the standards deploy writes
#                      (.github/workflows/<w> for w in DEPLOYABLE_WORKFLOWS of
#                      deploy-standard-workflows.sh), added or modified only.
#
# Each check is a pure function over JSON already fetched: it prints nothing and
# returns 0 when the input passes, or prints a one-line reason and returns 1.
# Anything unexpected (empty, malformed, truncated) is a rejection — fail closed.
# ssp_fetch_and_verify is the thin I/O wrapper the script calls.
#
# shellcheck shell=bash

if [ -n "${_SSP_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_SSP_SOURCED=1

# The PR commits endpoint returns at most 250 commits; at or above that the list
# may be truncated and cannot prove every commit was checked.
SSP_MAX_COMMITS=250

# ssp_allowed_paths <deploy-standard-workflows.sh>
#
# Prints the repo paths the standards deploy is allowed to write, one per line:
# `.github/workflows/<w>` for each <w> in the deploy script's DEPLOYABLE_WORKFLOWS
# — the authoritative list of stubs it deploys. The script is sourced in a
# subshell (its main() only runs when executed directly). Returns 1 and prints
# nothing if the list cannot be loaded or holds an entry that is not a plain
# workflow filename.
ssp_allowed_paths() {
  local deploy_script="$1" list w out=""
  [ -f "$deploy_script" ] || return 1
  list=$(
    # shellcheck source=/dev/null
    source "$deploy_script" >/dev/null 2>&1 || exit 1
    printf '%s\n' "${DEPLOYABLE_WORKFLOWS[@]}"
  ) 2>/dev/null || return 1
  [ -n "$list" ] || return 1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case "$w" in
      *[!A-Za-z0-9._-]*|.*) return 1 ;;
      *.yml|*.yaml) ;;
      *) return 1 ;;
    esac
    out+=".github/workflows/${w}"$'\n'
  done <<< "$list"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# ssp_check_commits <commits-json-array> <deployer-login> <head-sha>
ssp_check_commits() {
  local commits="$1" deployer="$2" head_sha="$3" reason
  [ -n "$deployer" ] && [ -n "$head_sha" ] || { echo "no deployer or head SHA to verify against"; return 1; }
  reason=$(jq -r --arg d "$deployer" --arg h "$head_sha" --argjson max "$SSP_MAX_COMMITS" '
    if type != "array" then "commit list is not an array"
    elif length == 0 then "PR has no commits"
    elif length >= $max then "PR has \(length) commits (API cap \($max)); cannot verify them all"
    elif (.[-1].sha // "") != $h then "commit list ends at \(.[-1].sha // "?"), not head \($h)"
    else
      [ .[]
        | (.author.login // "") as $a
        | (.committer.login // "") as $c
        | select(
            $a != $d
            or ($c != $d and ($c != "web-flow" or (.commit.verification.verified // false) != true))
          )
        | "commit \(.sha // "?") author=\($a | if . == "" then "<unlinked>" else . end) committer=\($c | if . == "" then "<unlinked>" else . end) is not the deployer \($d)"
      ] | first // ""
    end' <<< "$commits" 2>/dev/null) || { echo "commit list is not valid JSON"; return 1; }
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 1
  fi
  return 0
}

# ssp_check_pushes <activity-json-array> <deployer-login> <head-sha>
#
# <activity-json-array> is GET /repos/{o}/{r}/activity?ref=refs/heads/<branch>.
ssp_check_pushes() {
  local activity="$1" deployer="$2" head_sha="$3" reason
  [ -n "$deployer" ] && [ -n "$head_sha" ] || { echo "no deployer or head SHA to verify against"; return 1; }
  reason=$(jq -r --arg d "$deployer" --arg h "$head_sha" '
    if type != "array" then "branch activity is not an array"
    elif length == 0 then "no recorded pushes for the head branch"
    else
      ([ .[] | select((.actor.login // "") != $d)
         | "\(.activity_type // "ref update") to \(.after // "?") by \(.actor.login // "<unknown>"), not the deployer \($d)" ]
       | first) as $foreign
      | if $foreign then $foreign
        elif ((sort_by(.timestamp // "") | last | .after) // "") != $h
          then "newest recorded push is \((sort_by(.timestamp // "") | last | .after) // "?"), not head \($h)"
        else "" end
    end' <<< "$activity" 2>/dev/null) || { echo "branch activity is not valid JSON"; return 1; }
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 1
  fi
  return 0
}

# ssp_check_files <files-json-array> <allowed-paths (newline-separated)>
ssp_check_files() {
  local files="$1" allowed="$2" reason
  [ -n "$allowed" ] || { echo "standards-deploy path allowlist is unavailable (DEPLOYABLE_WORKFLOWS could not be loaded from deploy-standard-workflows.sh; it needs bash 4+)"; return 1; }
  reason=$(jq -r --arg allowed "$allowed" '
    ($allowed | split("\n") | map(select(length > 0))) as $ok
    | if type != "array" then "changed-file list is not an array"
      elif length == 0 then "PR changes no files"
      else
        [ .[]
          | (.filename // "") as $f
          | (.status // "") as $s
          | select(($s != "added" and $s != "modified") or (any($ok[]; . == $f) | not))
          | "\($s) \($f) is outside the standards-deploy scope"
        ] | first // ""
      end' <<< "$files" 2>/dev/null) || { echo "changed-file list is not valid JSON"; return 1; }
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 1
  fi
  return 0
}

# ssp_fetch_and_verify <owner/repo> <pr> <head-branch> <head-sha> <deployer> <allowed-paths>
#
# Reads the PR's commits and changed files (paginated) and the head branch's
# recorded ref updates, then runs the three checks. Prints a reason and returns
# 1 on the first failure — including any read failure — else returns 0.
ssp_fetch_and_verify() {
  local repo="$1" pr="$2" branch="$3" head_sha="$4" deployer="$5" allowed="$6"
  local commits files activity ref_q
  [ -n "$head_sha" ] || { echo "PR head SHA is unknown"; return 1; }
  [ -n "$branch" ] || { echo "PR head branch is unknown"; return 1; }
  ref_q=$(jq -rn --arg r "refs/heads/${branch}" '$r | @uri')

  commits=$(gh api --paginate "repos/${repo}/pulls/${pr}/commits?per_page=100" --jq '.[]' 2>/dev/null) \
    || { echo "could not read the PR's commits"; return 1; }
  commits=$(jq -sc '.' <<< "$commits" 2>/dev/null) || { echo "commit list is not valid JSON"; return 1; }
  ssp_check_commits "$commits" "$deployer" "$head_sha" || return 1

  activity=$(gh api --paginate "repos/${repo}/activity?ref=${ref_q}&per_page=100" --jq '.[]' 2>/dev/null) \
    || { echo "could not read the head branch's push activity"; return 1; }
  activity=$(jq -sc '.' <<< "$activity" 2>/dev/null) || { echo "branch activity is not valid JSON"; return 1; }
  ssp_check_pushes "$activity" "$deployer" "$head_sha" || return 1

  files=$(gh api --paginate "repos/${repo}/pulls/${pr}/files?per_page=100" --jq '.[]' 2>/dev/null) \
    || { echo "could not read the PR's changed files"; return 1; }
  files=$(jq -sc '.' <<< "$files" 2>/dev/null) || { echo "changed-file list is not valid JSON"; return 1; }
  ssp_check_files "$files" "$allowed" || return 1

  return 0
}
