#!/usr/bin/env bats
# The compliance audit skips NOT_SERVED_REPOS (scripts/lib/not-served-repos.sh).
#
# software-factory and software-factory-canary are outside the org standard by a
# recorded decision of the Maintainer. The deploy sweep already leaves them alone
# (#1334); the audit kept filing findings and issues there (#1343: 43 of 67
# findings, #1352). main() must drop them from the org listing, so they are not
# audited and the issue-management loop never creates issues or labels there.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/compliance-audit.sh"
  REPORT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/nsr.XXXXXX")"
  export REPORT_DIR SCRIPT
}

# _run_main <apply:true|false> — source the audit, stub every gh call and every
# per-repo check, feed main() an org listing with served and not-served repos,
# and echo which repos were audited and which reached issue management.
_run_main() {
  APPLY_FLAG="$1" run bash -c '
    source "$SCRIPT" >/dev/null 2>&1
    gh() {
      case "$1 $2" in
        "auth status") return 0 ;;
        "repo list") printf "%s\n" markets software-factory Software-Factory-Canary broodly ;;
        *) return 0 ;;
      esac
    }
    gh_api() { echo "{\"name\":\"x\"}"; }
    for f in $(declare -F | awk "{print \$3}" | grep -E "^(check_|pp_run_all_checks$|detect_ecosystems$)"); do
      eval "$f() { :; }"
    done
    detect_ecosystems() { ECOSYSTEMS=(); }
    check_required_workflows() { echo "AUDITED $1"; }
    ensure_audit_label() { echo "MANAGED $1"; }
    ensure_required_labels() { :; }
    create_issue_for_finding() { :; }
    close_resolved_issues() { :; }
    create_umbrella_issue() { :; }
    append_issue_pr_links() { :; }
    export GH_TOKEN=dummy
    if [ "$APPLY_FLAG" = true ]; then main --apply; else main; fi
  '
}

@test "main audits served repos and skips not-served ones" {
  _run_main false
  [[ "$output" == *"AUDITED markets"* ]]
  [[ "$output" == *"AUDITED broodly"* ]]
  [[ "$output" != *"AUDITED software-factory"* ]]
  [[ "$output" != *"AUDITED Software-Factory-Canary"* ]]
}

@test "the issue-management loop never reaches a not-served repo" {
  _run_main true
  [[ "$output" == *"MANAGED markets"* ]]
  [[ "$output" != *"MANAGED software-factory"* ]]
  [[ "$output" != *"MANAGED Software-Factory-Canary"* ]]
}

@test "not-served repos are not counted in the audited-repos record" {
  _run_main false
  run cat "$REPORT_DIR/audited-repos.txt"
  [[ "$output" == *"markets"* ]]
  [[ "$output" != *"software-factory"* ]]
  [[ "$output" != *"Software-Factory-Canary"* ]]
}

# The shared list itself (scripts/lib/not-served-repos.sh). This file runs on any
# scripts/lib/** change (compliance-audit-tests.yml), so the lib is covered here.
@test "is_not_served_repo: software-factory and its canary, case-insensitively" {
  run bash -c 'source "$1"; is_not_served_repo software-factory && is_not_served_repo SOFTWARE-FACTORY-CANARY' _ "${REPO_ROOT}/scripts/lib/not-served-repos.sh"
  [ "$status" -eq 0 ]
}

@test "is_not_served_repo: ordinary repos, .github and .github-private are served" {
  run bash -c 'source "$1"; for r in markets .github .github-private software-factory-other ""; do is_not_served_repo "$r" && { echo "$r"; exit 1; }; done; exit 0' _ "${REPO_ROOT}/scripts/lib/not-served-repos.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
