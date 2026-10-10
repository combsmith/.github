#!/usr/bin/env bash
# Fact gathering for the auto-rebase update gate (issue #1272).
#
# I/O glue: reads the base branch's rules and the PR's mergeability state through `gh`, and polls while GitHub computes
# mergeability. It makes NO decision itself — the verdict comes from the pure
# auto_rebase_gate_decide in update-gate.sh, which must be sourced alongside.
#
# Tested by test/workflows/auto-rebase/update-gate.bats.
# Contract: see .github/scripts/auto-rebase/README.md

# auto_rebase_strict_policy REPO BRANCH
#   Prints `true` if the branch's effective rules require branches to be up to
#   date, `false` if they do not, `unknown` if that could not be determined.
#   Always returns 0.
auto_rebase_strict_policy() {
  local repo="$1" branch="$2" out strict msg

  # Rulesets: the effective (active) rules for the branch, from every ruleset
  # that targets it (repo- and org-level). Readable with read access.
  if ! out=$(gh api "repos/${repo}/rules/branches/${branch}?per_page=100" --paginate --slurp 2>/dev/null); then
    echo unknown
    return 0
  fi
  strict=$(printf '%s' "$out" | jq -r '
    if type == "array" then
      [flatten[] | select(.type == "required_status_checks")
           | (.parameters.strict_required_status_checks_policy == true
              and ((.parameters.required_status_checks // []) | length) > 0)] | any
    else "invalid" end' 2>/dev/null) || strict=""
  case "$strict" in
    true) echo true; return 0 ;;
    false) ;;
    *) echo unknown; return 0 ;;
  esac

  # Classic branch protection. A 404 naming the absence of protection / status
  # checks means "not strict"; any other failure (e.g. 403 for a token without
  # admin access) means the configuration is unreadable.
  if out=$(gh api "repos/${repo}/branches/${branch}/protection/required_status_checks" 2>/dev/null); then
    strict=$(printf '%s' "$out" | jq -r '.strict | if type == "boolean" then tostring else "invalid" end' 2>/dev/null) || strict=""
    case "$strict" in
      true|false) echo "$strict" ;;
      *) echo unknown ;;
    esac
    return 0
  fi
  msg=$(printf '%s' "$out" | jq -r '.message // empty' 2>/dev/null) || msg=""
  case "$msg" in
    "Branch not protected"|"Required status checks not enabled") echo false ;;
    *) echo unknown ;;
  esac
  return 0
}

# auto_rebase_pr_mergeable REPO PR_NUMBER
#   Prints the PR's GraphQL MergeableState (MERGEABLE|CONFLICTING|UNKNOWN);
#   UNKNOWN when it cannot be read. Always returns 0.
auto_rebase_pr_mergeable() {
  local repo="$1" pr="$2" out state
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions
  local query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){mergeable}}}'

  if ! out=$(gh api graphql -f query="$query" -f owner="${repo%%/*}" \
      -f name="${repo#*/}" -F number="$pr" 2>/dev/null); then
    echo UNKNOWN
    return 0
  fi
  state=$(printf '%s' "$out" | jq -r '.data.repository.pullRequest.mergeable // "UNKNOWN"' 2>/dev/null) || state=""
  echo "${state:-UNKNOWN}"
  return 0
}

# auto_rebase_update_decision STRICT REPO PR_NUMBER
#   Applies auto_rebase_gate_decide, re-polling while GitHub is still computing
#   mergeability (common right after a base push). Prints the reason; returns
#   0 (update) or 1 (skip).
#   Tunables: AUTO_REBASE_MERGEABLE_POLLS (default 5),
#             AUTO_REBASE_MERGEABLE_POLL_SECONDS (default 3).
auto_rebase_update_decision() {
  local strict="$1" repo="$2" pr="$3"
  local polls="${AUTO_REBASE_MERGEABLE_POLLS:-5}"
  local delay="${AUTO_REBASE_MERGEABLE_POLL_SECONDS:-3}"
  local mergeable reason rc i

  if [[ "$strict" != "false" ]]; then
    auto_rebase_gate_decide "$strict" ""
    return 0
  fi

  for ((i = 1; i <= polls; i++)); do
    mergeable=$(auto_rebase_pr_mergeable "$repo" "$pr")
    rc=0
    reason=$(auto_rebase_gate_decide "$strict" "$mergeable") || rc=$?
    if [[ "$rc" -ne 3 ]]; then
      echo "$reason"
      return "$rc"
    fi
    if [[ "$i" -lt "$polls" ]]; then sleep "$delay"; fi
  done
  echo "could not evaluate (mergeability still unknown after ${polls} checks) — updating as before"
  return 0
}
