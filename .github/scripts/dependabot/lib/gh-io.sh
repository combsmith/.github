#!/usr/bin/env bash
# GitHub I/O glue for the Dependabot reusables (issues #1399, #1400).
#
# Reads PR / check / commit / ruleset state through `gh` and performs the
# privileged writes (approve, enable auto-merge, merge, revoke). It makes NO
# decision itself — every verdict comes from the pure gates in lib/gates.sh,
# which must be sourced alongside. Any read failure fails closed (skip).
#
# Tested by test/workflows/dependabot/gh-io.bats and the end-to-end suites in
# test/workflows/dependabot/.
# Contract: see .github/scripts/dependabot/README.md

# dependabot_fetch_pr_state REPO PR_NUMBER
#   Prints the GraphQL pullRequest object (headRefOid, baseRefName, mergeable,
#   autoMergeRequest and the head commit's check rollup). Returns 1 on failure.
dependabot_fetch_pr_state() {
  local repo="$1" pr="$2" out
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
  local query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid baseRefName mergeable autoMergeRequest{enabledAt} commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{__typename ... on CheckRun{name status conclusion} ... on StatusContext{context state}}}}}}}}}}'

  out=$(gh api graphql -f query="$query" -f owner="${repo%%/*}" \
      -f name="${repo#*/}" -F number="$pr" 2>/dev/null) || return 1
  out=$(jq -c '.data.repository.pullRequest // empty' <<<"$out" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  echo "$out"
}

# dependabot_fetch_required_contexts REPO BRANCH
#   Prints a JSON array of the status-check names the branch's active rules
#   require. Returns 1 when the rules cannot be read.
dependabot_fetch_required_contexts() {
  local repo="$1" branch="$2" out
  out=$(gh api "repos/${repo}/rules/branches/${branch}?per_page=100" \
      --paginate --slurp 2>/dev/null) || return 1
  dependabot_required_contexts "$out"
}

# dependabot_fetch_pr REPO PR_NUMBER — prints the REST pull request object.
dependabot_fetch_pr() {
  local repo="$1" pr="$2"
  gh api "repos/${repo}/pulls/${pr}" 2>/dev/null
}

# dependabot_fetch_pr_commits REPO PR_NUMBER — prints every page of the PR's
# commits (REST, as `--paginate --slurp` pages).
dependabot_fetch_pr_commits() {
  local repo="$1" pr="$2"
  gh api "repos/${repo}/pulls/${pr}/commits?per_page=100" --paginate --slurp 2>/dev/null
}

# dependabot_provenance_check REPO PR_NUMBER TRUSTED_MERGE_LOGIN [EXPECTED_SHA]
#   Reads the PR and all its commits, then applies dependabot_provenance_gate.
#   Sets DEPENDABOT_GATE_REASON, and DEPENDABOT_GATE_SHA (the verified head) on
#   pass. DEPENDABOT_GATE_STALE=true when the head is no longer EXPECTED_SHA
#   (a newer push; the run for that push decides).
#   Returns 0 pass, 1 block (a verdict), 2 block (the state could not be read —
#   no verdict; callers should not act on it beyond not approving/merging).
dependabot_provenance_check() {
  local repo="$1" pr="$2" trusted="${3:-}" expected="${4:-}" pr_json commits_json head
  DEPENDABOT_GATE_SHA=""
  DEPENDABOT_GATE_REASON=""
  DEPENDABOT_GATE_STALE=false

  if ! pr_json=$(dependabot_fetch_pr "$repo" "$pr"); then
    DEPENDABOT_GATE_REASON="could not read the pull request"
    return 2
  fi
  head=$(jq -r '.head.sha // empty' <<<"$pr_json" 2>/dev/null) || head=""
  if [[ -n "$expected" && -n "$head" && "$head" != "$expected" ]]; then
    # shellcheck disable=SC2034 # read by the workflow glue
    DEPENDABOT_GATE_STALE=true
    DEPENDABOT_GATE_REASON="head moved to ${head:0:7} (expected ${expected:0:7})"
    return 1
  fi
  if ! commits_json=$(dependabot_fetch_pr_commits "$repo" "$pr"); then
    DEPENDABOT_GATE_REASON="could not read the pull request's commits"
    return 2
  fi
  if ! DEPENDABOT_GATE_REASON=$(dependabot_provenance_gate "$pr_json" "$commits_json" "$trusted" "$expected"); then
    return 1
  fi
  DEPENDABOT_GATE_SHA="$head"
  [[ -n "$DEPENDABOT_GATE_SHA" ]]
}

# dependabot_merge_gate REPO PR_NUMBER TRUSTED_MERGE_LOGIN
#   Decides whether the merger may merge the PR now: auto-merge requested,
#   MERGEABLE, every check on the head commit successful (incl. every check the
#   base branch's rules require), and every commit from Dependabot (or a branch
#   update by TRUSTED_MERGE_LOGIN) — all bound to one head SHA.
#   Sets DEPENDABOT_GATE_REASON, and DEPENDABOT_GATE_SHA on pass.
#   Returns 0 merge / 1 skip.
dependabot_merge_gate() {
  local repo="$1" pr="$2" trusted="${3:-}" state head base required reason
  DEPENDABOT_GATE_SHA=""
  DEPENDABOT_GATE_REASON=""

  if ! state=$(dependabot_fetch_pr_state "$repo" "$pr"); then
    DEPENDABOT_GATE_REASON="could not read the pull request state"
    return 1
  fi
  if [[ "$(jq -r '.autoMergeRequest != null' <<<"$state")" != "true" ]]; then
    DEPENDABOT_GATE_REASON="auto-merge not enabled"
    return 1
  fi
  if [[ "$(jq -r '.mergeable // "UNKNOWN"' <<<"$state")" != "MERGEABLE" ]]; then
    DEPENDABOT_GATE_REASON="not mergeable ($(jq -r '.mergeable // "UNKNOWN"' <<<"$state"))"
    return 1
  fi
  head=$(jq -r '.headRefOid // empty' <<<"$state")
  base=$(jq -r '.baseRefName // empty' <<<"$state")
  if [[ -z "$head" || -z "$base" ]]; then
    DEPENDABOT_GATE_REASON="could not read the head commit / base branch"
    return 1
  fi
  if ! required=$(dependabot_fetch_required_contexts "$repo" "$base"); then
    DEPENDABOT_GATE_REASON="could not read the required checks for ${base}"
    return 1
  fi
  if ! reason=$(dependabot_checks_gate "$state" "$required" "$head"); then
    DEPENDABOT_GATE_REASON="$reason"
    return 1
  fi
  if ! dependabot_provenance_check "$repo" "$pr" "$trusted" "$head"; then
    DEPENDABOT_GATE_SHA=""
    return 1
  fi
  DEPENDABOT_GATE_REASON="${reason}; ${DEPENDABOT_GATE_REASON}"
  DEPENDABOT_GATE_SHA="$head"
}

# dependabot_merge_pr REPO PR_NUMBER SHA
#   Squash-merges the PR, bound to SHA: GitHub refuses the merge (409) if the
#   head moved after it was verified.
dependabot_merge_pr() {
  local repo="$1" pr="$2" sha="$3"
  [[ -n "$sha" ]] || return 1
  gh api "repos/${repo}/pulls/${pr}/merge" -X PUT \
    -f merge_method=squash -f sha="$sha" --silent
}

# dependabot_approve_and_automerge REPO PR_NUMBER SHA
#   Approves the PR at commit SHA (the review is bound to that commit) and
#   enables squash auto-merge only while the head is still SHA.
dependabot_approve_and_automerge() {
  local repo="$1" pr="$2" sha="$3"
  [[ -n "$sha" ]] || return 1
  gh api "repos/${repo}/pulls/${pr}/reviews" -X POST \
    -f event=APPROVE -f commit_id="$sha" --silent || return 1
  gh pr merge "$pr" --repo "$repo" --auto --squash --match-head-commit "$sha"
}

# dependabot_revoke_automation REPO PR_NUMBER APP_LOGIN REASON
#   Best effort, always returns 0: disables auto-merge and dismisses approvals
#   APP_LOGIN gave earlier, so a revision that failed the provenance gate is not
#   merged on the strength of an approval of an earlier revision.
dependabot_revoke_automation() {
  local repo="$1" pr="$2" app_login="$3" reason="$4" reviews id

  if ! gh pr merge "$pr" --repo "$repo" --disable-auto >/dev/null 2>&1; then
    echo "  auto-merge was not enabled (or could not be disabled)"
  else
    echo "  Disabled auto-merge"
  fi

  [[ -n "$app_login" ]] || return 0
  if ! reviews=$(gh api "repos/${repo}/pulls/${pr}/reviews?per_page=100" --paginate --slurp 2>/dev/null); then
    echo "::warning::Could not list reviews on PR #${pr} to dismiss earlier automated approvals"
    return 0
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if gh api "repos/${repo}/pulls/${pr}/reviews/${id}/dismissals" -X PUT \
        -f event=DISMISS -f message="Automated approval withdrawn: ${reason}" --silent; then
      echo "  Dismissed automated approval ${id}"
    else
      echo "::warning::Could not dismiss automated approval ${id} on PR #${pr}"
    fi
  done < <(jq -r --arg login "$app_login" \
      'flatten[] | select(.user.login == $login and .state == "APPROVED") | .id' \
      <<<"$reviews" 2>/dev/null)
  return 0
}
