#!/usr/bin/env bats
# Tests for dl_dev_lead_active (scripts/lib/dev-lead-retrigger.sh): only a PR
# opened BY the dev-lead agent FROM the repository itself counts as "dev-lead is
# already working this issue" (combsmith/.github#1391).
#
# The open-PR list includes fork PRs, and a fork contributor chooses its head
# branch name freely, so a `dev-lead/issue-<n>-*` branch name alone must not
# suppress the compliance retrigger. The `gh` stub below evaluates the real
# `--jq` filter against a fixture, so these tests exercise the actual selector.

bats_require_minimum_version 1.5.0

setup() {
  TT_REPO_ROOT="$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PULLS_FIXTURE="${BATS_TEST_TMPDIR}/pulls.json"
  GH_FAIL_PULLS=0
  unset DEV_LEAD_LOGINS
  # shellcheck source=/dev/null
  . "${TT_REPO_ROOT}/scripts/lib/dev-lead-retrigger.sh"
}

# gh stub: apply the caller's --jq filter to the pulls fixture (or to an issue
# with no labels), mimicking `gh api --jq`.
gh() {
  local path="" filter="" arg prev=""
  for arg in "$@"; do
    case "$prev" in --jq) filter="$arg" ;; esac
    case "$arg" in repos/*) path="$arg" ;; esac
    prev="$arg"
  done
  case "$path" in
    */pulls\?*)
      [ "$GH_FAIL_PULLS" -eq 0 ] || return 1
      jq "$filter" "$PULLS_FIXTURE"
      ;;
    */issues/*/events*) printf '' ;;
    */issues/*) printf '{"labels":[]}' | jq -r "$filter" ;;
    *) return 1 ;;
  esac
}

# pr_json <head_ref> <head_full_name|null> <author_login>
pr_json() {
  local head_repo
  if [ "$2" = "null" ]; then head_repo=null; else head_repo="{\"full_name\":\"$2\"}"; fi
  printf '{"number":1,"head":{"ref":"%s","repo":%s},"base":{"ref":"main","repo":{"full_name":"combsmith/widget"}},"user":{"login":"%s"}}' \
    "$1" "$head_repo" "$3"
}

write_pulls() {
  local IFS=,
  printf '[%s]' "$*" >"$PULLS_FIXTURE"
}

@test "active: same-repo dev-lead branch PR authored by the agent identity" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 combsmith/widget don-petry)"
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 0 ]
}

@test "inactive: a FORK PR on a dev-lead/issue-<n>- branch does not suppress the retrigger" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 mallory/widget mallory)"
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 1 ]
}

@test "inactive: a fork PR is rejected even when its author is the agent login" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 don-petry/widget don-petry)"
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 1 ]
}

@test "inactive: a same-repo dev-lead branch PR by someone other than the agent" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 combsmith/widget some-contributor)"
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 1 ]
}

@test "inactive: a PR whose head repo was deleted (head.repo null) does not count" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 null don-petry)"
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 1 ]
}

@test "active: the agent PR is found among fork decoys" {
  write_pulls \
    "$(pr_json dev-lead/issue-7-20261027-1100 mallory/widget mallory)" \
    "$(pr_json dev-lead/issue-7-20261027-1200 combsmith/widget don-petry)"
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 0 ]
}

@test "issue-number prefix stays exact: issue 1 does not match an issue-12 branch" {
  write_pulls "$(pr_json dev-lead/issue-12-20261027-1200 combsmith/widget don-petry)"
  run dl_dev_lead_active combsmith widget 1
  [ "$status" -eq 1 ]
}

@test "DEV_LEAD_LOGINS overrides the trusted agent identity (comma-separated)" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 combsmith/widget other-agent)"
  DEV_LEAD_LOGINS="don-petry, other-agent" run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 0 ]
  DEV_LEAD_LOGINS="don-petry" run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 1 ]
}

@test "DEV_LEAD_LOGINS values cannot inject into the jq filter" {
  write_pulls "$(pr_json dev-lead/issue-7-20261027-1200 combsmith/widget mallory)"
  DEV_LEAD_LOGINS='x"] or true or ["' run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 1 ]
}

@test "fail-closed preserved: a failing PR lookup still reports active" {
  write_pulls
  GH_FAIL_PULLS=1
  run dl_dev_lead_active combsmith widget 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"treating as active"* ]]
}
