#!/usr/bin/env bats
# Tests for check_nosonar_markers in scripts/compliance-audit.sh (#1613): the
# org-wide sweep of inline NOSONAR markers and deprecated sonar.issue.ignore keys.
# gh is mocked; the mock answers each `gh api <path> --jq ...` call with the value
# the real --jq expression would print. The marker rule itself is unit-tested in
# test/scripts/nosonar-markers/.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() { rm -rf "$TEST_TMP"; }

b64() { printf '%s\n' "$1" | base64 | tr -d '\n'; }

# _run_check <gh-mock-case-body>: the body is a `case "$2" in ... esac` arm list.
_run_check() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$2" in\n%s\n  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;\nesac\n' "$1"
  } > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" SONAR_MARKER_SEARCH_DELAY=0 bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    INCONCLUSIVE_REPOS_FILE="$REPORT_DIR/inconclusive.txt"
    check_nosonar_markers "demo"
    cat "$REPORT_DIR/findings.json"
    echo "INCONCLUSIVE=$(cat "$REPORT_DIR/inconclusive.txt" 2>/dev/null)"
  '
}

SONAR_ARM='  repos/combsmith/demo/contents/.github/workflows/sonarcloud.yml) echo sonarcloud.yml ;;'

@test "repo without sonarcloud.yml is skipped" {
  run _run_check '  search/*) echo "a.py" ;;'
  [ "$status" -eq 0 ]
  [[ "$output" != *"nosonar-marker-invalid"* ]]
  [[ "$output" != *"sonar-issue-ignore-deprecated"* ]]
}

@test "valid markers produce no finding" {
  good=$(b64 '    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable')
  run _run_check "$SONAR_ARM
  search/*) echo .github/workflows/ci.yml ;;
  repos/combsmith/demo/contents/.github/workflows/ci.yml) echo $good ;;"
  [ "$status" -eq 0 ]
  [[ "$output" != *"nosonar-marker-invalid"* ]]
  [[ "$output" == *"INCONCLUSIVE="* ]]
  [[ "$output" != *"INCONCLUSIVE=demo"* ]]
}

@test "bare and mis-keyed markers file nosonar-marker-invalid with locations" {
  bad_py=$(b64 'x = 1  # NOSONAR(python:S117) legacy')
  bad_yml=$(b64 '    secrets: inherit  # NOSONAR')
  run _run_check "$SONAR_ARM
  search/*) printf '%s\n' src/a.py .github/workflows/x.yml README.md ;;
  repos/combsmith/demo/contents/src/a.py) echo $bad_py ;;
  repos/combsmith/demo/contents/.github/workflows/x.yml) echo $bad_yml ;;"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"check": "nosonar-marker-invalid"'* ]]
  [[ "$output" == *'"severity": "warning"'* ]]
  [[ "$output" == *"2 inline NOSONAR marker(s)"* ]]
  [[ "$output" == *'src/a.py:1'* ]]
  [[ "$output" == *'.github/workflows/x.yml:1'* ]]
}

@test "sonar.issue.ignore keys file sonar-issue-ignore-deprecated" {
  props=$(b64 "$(printf 'sonar.projectKey=x\nsonar.issue.ignore.multicriteria=a\nsonar.issue.ignore.multicriteria.a.ruleKey=githubactions:S7637\n')")
  run _run_check "$SONAR_ARM
  repos/combsmith/demo/contents/sonar-project.properties) echo $props ;;
  search/*) : ;;"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"check": "sonar-issue-ignore-deprecated"'* ]]
  [[ "$output" == *"carries 2"* ]]
}

@test "a failed code search marks the repo inconclusive, not clean" {
  run _run_check "$SONAR_ARM
  search/*) echo 'gh: rate limited (HTTP 403)' >&2; exit 1 ;;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INCONCLUSIVE=demo"* ]]
  [[ "$output" != *"nosonar-marker-invalid"* ]]
}
