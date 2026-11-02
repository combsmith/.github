#!/usr/bin/env bash
# GitHub I/O glue for the Dependabot reusables (issues #1399, #1400).
#
# Reads PR / check / commit / ruleset state through `gh` and performs the
# privileged writes (approve, enable auto-merge, merge, revoke). It makes NO
# decision itself — every verdict comes from the pure gates in lib/gates.sh,
# which must be sourced alongside. Any read failure fails closed (skip).
#
# Tested end to end by test/workflows/dependabot/automerge-provenance.bats and
# test/workflows/dependabot/rebase-merge-gate.bats.
# Contract: see .github/scripts/dependabot/README.md

# dependabot_fetch_pr_state REPO PR_NUMBER
#   Prints the GraphQL pullRequest object (headRefOid, baseRefName, mergeable,
#   autoMergeRequest and the head commit's check rollup). Returns 1 on failure.
dependabot_fetch_pr_state() {
  local repo="$1" pr="$2" out
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
  local query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid baseRefName mergeable autoMergeRequest{enabledAt} commits(last:1){nodes{commit{oid statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{__typename ... on CheckRun{name status conclusion checkSuite{app{slug}}} ... on StatusContext{context state}}}}}}}}}}'

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
#   MERGEABLE, every check on the head commit other than agent jobs successful
#   (incl. every check the base branch's rules require), and every commit from Dependabot (or a branch
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

# dependabot_approve_and_automerge REPO PR_NUMBER SHA APP_LOGIN
#   Approves the PR at commit SHA and enables squash auto-merge only while the
#   head is still SHA, then re-reads the PR, because neither write is atomic
#   with the head: GitHub accepts a review for an older commit, the App's
#   approval is not subject to the stale-review rules (it is a bypass actor),
#   and a push by a writer does not disable auto-merge that is already on.
#
#   The re-read closes the race with the run for a newer push. That push came
#   either before this re-read (seen here) or after it, in which case its own
#   run starts after these writes and revokes them. So whichever way the runs
#   interleave, an unverified head does not keep this state.
#
#   Returns 0 when the state is settled: SHA is still the head and auto-merge
#   is on, or the head moved and the state was withdrawn. Returns non-zero when
#   auto-merge was refused at SHA, the PR could not be re-read (the state is
#   withdrawn first), or a withdrawal could not be completed.
dependabot_approve_and_automerge() {
  local repo="$1" pr="$2" sha="$3" app_login="${4:-}" enable_rc=0 rc=0
  [[ -n "$sha" ]] || return 1
  gh api "repos/${repo}/pulls/${pr}/reviews" -X POST \
    -f event=APPROVE -f commit_id="$sha" --silent || return 1
  gh pr merge "$pr" --repo "$repo" --auto --squash --match-head-commit "$sha" || enable_rc=$?

  GH_TOKEN="${READ_TOKEN:-${GH_TOKEN:-}}" dependabot_provenance_check "$repo" "$pr" "$app_login" || rc=$?
  case "$rc" in
    0)
      if [[ "$DEPENDABOT_GATE_SHA" == "$sha" ]]; then
        return "$enable_rc"
      fi
      # A newer verified head: its own run owns approval and auto-merge, so
      # withdraw only what this run approved for the older commit.
      echo "Head moved to ${DEPENDABOT_GATE_SHA:0:7} during approval; withdrawing the approval of ${sha:0:7}"
      dependabot_dismiss_app_approvals "$repo" "$pr" "$app_login" \
        "the head moved past ${sha:0:7}" "$DEPENDABOT_GATE_SHA"
      ;;
    1)
      echo "::warning::Withdrawing automation on PR #${pr} — ${DEPENDABOT_GATE_REASON}"
      dependabot_revoke_automation "$repo" "$pr" "$app_login" "$DEPENDABOT_GATE_REASON"
      ;;
    *)
      echo "::error::Could not re-verify PR #${pr} after approving — ${DEPENDABOT_GATE_REASON}; withdrawing"
      dependabot_revoke_automation "$repo" "$pr" "$app_login" "$DEPENDABOT_GATE_REASON" || true
      return 1
      ;;
  esac
}

# dependabot_dismiss_app_approvals REPO PR_NUMBER APP_LOGIN REASON [KEEP_SHA]
#   Dismisses APP_LOGIN's approvals, except those of commit KEEP_SHA. Returns 1
#   when an approval may have survived (the login is unknown, the reviews could
#   not be listed, or a dismissal failed).
dependabot_dismiss_app_approvals() {
  local repo="$1" pr="$2" app_login="$3" reason="$4" keep="${5:-}" reviews ids id failed=0

  if [[ -z "$app_login" ]]; then
    echo "::error::Cannot identify automated approvals on PR #${pr}: no App login"
    return 1
  fi
  if ! reviews=$(gh api "repos/${repo}/pulls/${pr}/reviews?per_page=100" --paginate --slurp 2>/dev/null); then
    echo "::error::Could not list reviews on PR #${pr} to dismiss automated approvals"
    return 1
  fi
  if ! ids=$(jq -r --arg login "$app_login" --arg keep "$keep" \
      'flatten[] | select(.user.login == $login and .state == "APPROVED" and .commit_id != $keep) | .id' \
      <<<"$reviews" 2>/dev/null); then
    echo "::error::Could not parse reviews on PR #${pr} to dismiss automated approvals"
    return 1
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if gh api "repos/${repo}/pulls/${pr}/reviews/${id}/dismissals" -X PUT \
        -f event=DISMISS -f message="Automated approval withdrawn: ${reason}" --silent; then
      echo "  Dismissed automated approval ${id}"
    else
      echo "::error::Could not dismiss automated approval ${id} on PR #${pr}"
      failed=1
    fi
  done <<<"$ids"
  return "$failed"
}

# dependabot_revoke_automation REPO PR_NUMBER APP_LOGIN REASON
#   Disables auto-merge and dismisses every approval APP_LOGIN gave, so a
#   revision that failed the provenance gate is not merged on the strength of an
#   approval of an earlier one. Attempts both, then returns 1 unless the PR reads
#   back with auto-merge off and no approval failed to dismiss, so a withdrawal
#   that did not complete fails the run instead of passing silently.
dependabot_revoke_automation() {
  local repo="$1" pr="$2" app_login="$3" reason="$4" pr_json failed=0

  # `--disable-auto` also fails when auto-merge was never on, so the result is
  # judged from the PR below rather than from its exit status.
  if gh pr merge "$pr" --repo "$repo" --disable-auto >/dev/null 2>&1; then
    echo "  Disabled auto-merge"
  fi
  if ! pr_json=$(GH_TOKEN="${READ_TOKEN:-${GH_TOKEN:-}}" dependabot_fetch_pr "$repo" "$pr"); then
    echo "::error::Could not confirm auto-merge is off on PR #${pr}"
    failed=1
  elif [[ "$(jq -r '.auto_merge != null' <<<"$pr_json" 2>/dev/null)" != "false" ]]; then
    echo "::error::auto-merge is still enabled on PR #${pr}"
    failed=1
  fi

  dependabot_dismiss_app_approvals "$repo" "$pr" "$app_login" "$reason" || failed=1
  return "$failed"
}

# dependabot_withdraw_app_automation REPO PR_NUMBER APP_LOGIN REASON
#   For an update that no longer qualifies for automation: dismisses APP_LOGIN's
#   approvals and disables auto-merge only when APP_LOGIN enabled it, since a
#   human may have enabled it deliberately after reviewing. Returns 1 when the
#   state cannot be read or the withdrawal cannot be completed.
dependabot_withdraw_app_automation() {
  local repo="$1" pr="$2" app_login="$3" reason="$4" pr_json enabled_by

  if ! pr_json=$(GH_TOKEN="${READ_TOKEN:-${GH_TOKEN:-}}" dependabot_fetch_pr "$repo" "$pr"); then
    echo "::error::Could not read PR #${pr} to withdraw automation"
    return 1
  fi
  enabled_by=$(jq -r '.auto_merge.enabled_by.login // empty' <<<"$pr_json" 2>/dev/null) || enabled_by=""
  if [[ -n "$enabled_by" && "$enabled_by" == "$app_login" ]]; then
    dependabot_revoke_automation "$repo" "$pr" "$app_login" "$reason"
    return
  fi
  dependabot_dismiss_app_approvals "$repo" "$pr" "$app_login" "$reason"
}
