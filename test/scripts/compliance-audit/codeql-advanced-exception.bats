#!/usr/bin/env bats
# Tests for the advanced-CodeQL exception in check_codeql_default_setup
# (scripts/compliance-audit.sh) and its list in scripts/lib/codeql-advanced.sh.
#
# The org standard is CodeQL default setup with no codeql.yml. A repo with a
# merge queue cannot follow it: default setup never reports on `merge_group`, so
# the required `CodeQL` check would stall the queue. Such repos are listed in
# CODEQL_ADVANCED_EXCEPTIONS. Before this list was honoured the audit filed
# `stray-codeql-workflow` and `codeql-default-setup-not-configured` against them,
# and acting on either finding breaks the repo's merge queue.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  # No-op sleep so gh_api's retry path runs instantly.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() { rm -rf "$TEST_TMP"; }

# _run_check <repo> <gh-mock-body>: install a mock gh, source the audit, run
# check_codeql_default_setup on <repo>, and print findings.json.
_run_check() {
  printf '#!/usr/bin/env bash\nargs="$*"\n%s\n' "$2" > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" REPO="$1" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_codeql_default_setup "$REPO"
    cat "$REPORT_DIR/findings.json"
    if repo_has_inconclusive_checks "$REPO"; then echo "INCONCLUSIVE=yes"; else echo "INCONCLUSIVE=no"; fi
  '
}

# gh mock bodies. $args is the full argument string.
ADVANCED_STATE='case "$args" in
  *code-scanning/default-setup*) echo "{\"state\":\"not-configured\"}"; exit 0 ;;
  *workflows/codeql.yml*) echo "codeql.yml"; exit 0 ;;
esac
exit 0'

NOTHING_CONFIGURED='case "$args" in
  *code-scanning/default-setup*) echo "{\"state\":\"not-configured\"}"; exit 0 ;;
  *workflows/codeql.yml*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
exit 0'

UNREADABLE_WORKFLOW='case "$args" in
  *code-scanning/default-setup*) echo "{\"state\":\"not-configured\"}"; exit 0 ;;
  *workflows/codeql.yml*) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
esac
exit 0'

DEFAULT_SETUP_STILL_ON='case "$args" in
  *code-scanning/default-setup*) echo "{\"state\":\"configured\"}"; exit 0 ;;
  *workflows/codeql.yml*) echo "codeql.yml"; exit 0 ;;
esac
exit 0'

DEFAULT_SETUP_FORBIDDEN='case "$args" in
  *code-scanning/default-setup*) echo "{\"message\":\"Resource not accessible by personal access token\",\"status\":\"403\"}"; exit 1 ;;
  *workflows/codeql.yml*) echo "codeql.yml"; exit 0 ;;
esac
exit 0'

DEFAULT_SETUP_UNREACHABLE='case "$args" in
  *code-scanning/default-setup*) echo "error connecting to api.github.com" >&2; exit 1 ;;
  *workflows/codeql.yml*) echo "codeql.yml"; exit 0 ;;
esac
exit 0'

@test "listed repo with codeql.yml and default setup off → no finding" {
  run _run_check ".github" "$ADVANCED_STATE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"stray-codeql-workflow"* ]]
  [[ "$output" != *"codeql-default-setup-not-configured"* ]]
  [[ "$output" != *"codeql-advanced-workflow-missing"* ]]
}

@test "the same state on an unlisted repo still files both standard findings" {
  run _run_check "demo-repo" "$ADVANCED_STATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stray-codeql-workflow"* ]]
  [[ "$output" == *"codeql-default-setup-not-configured"* ]]
}

@test "listed repo with no codeql.yml → codeql-advanced-workflow-missing error" {
  run _run_check ".github" "$NOTHING_CONFIGURED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codeql-advanced-workflow-missing"* ]]
  [[ "$output" == *"error"* ]]
  [[ "$output" != *"codeql-default-setup-not-configured"* ]]
}

@test "listed repo whose codeql.yml cannot be read (403) → no finding, repo inconclusive" {
  # Not filed as missing, and not treated as present either: an open
  # codeql-advanced-workflow-missing issue must not be closed on this run.
  run _run_check ".github" "$UNREADABLE_WORKFLOW"
  [ "$status" -eq 0 ]
  [[ "$output" != *"codeql-advanced-workflow-missing"* ]]
  [[ "$output" != *"stray-codeql-workflow"* ]]
  [[ "$output" == *"INCONCLUSIVE=yes"* ]]
}

@test "listed repo in the approved state is not marked inconclusive" {
  run _run_check ".github" "$ADVANCED_STATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INCONCLUSIVE=no"* ]]
}

@test "listed repo with default setup still on → codeql-default-setup-conflicts-advanced error" {
  run _run_check ".github" "$DEFAULT_SETUP_STILL_ON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codeql-default-setup-conflicts-advanced"* ]]
  [[ "$output" == *"error"* ]]
  [[ "$output" != *"stray-codeql-workflow"* ]]
}

@test "listed repo, default-setup state forbidden to the audit token (403) → no finding, not inconclusive" {
  # The audit token routinely lacks this scope; holding issue closure on every
  # run for it would never clear.
  run _run_check ".github" "$DEFAULT_SETUP_FORBIDDEN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"codeql-default-setup-conflicts-advanced"* ]]
  [[ "$output" == *"INCONCLUSIVE=no"* ]]
}

@test "listed repo, default-setup state unreachable → no finding, repo inconclusive" {
  run _run_check ".github" "$DEFAULT_SETUP_UNREACHABLE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"codeql-default-setup-conflicts-advanced"* ]]
  [[ "$output" == *"INCONCLUSIVE=yes"* ]]
}

@test "the list holds both merge-queue repos and matches whole names only" {
  run bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/codeql-advanced.sh"
    codeql_advanced_exception ".github"         || { echo "missing .github"; exit 1; }
    codeql_advanced_exception ".github-private" || { echo "missing .github-private"; exit 1; }
    codeql_advanced_exception ".github-priv"    && { echo "prefix matched"; exit 1; }
    codeql_advanced_exception "github"          && { echo "substring matched"; exit 1; }
    codeql_advanced_exception ""                && { echo "empty matched"; exit 1; }
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "every listed repo is recorded in the standard's exception table" {
  local repo
  while IFS= read -r repo; do
    grep -Fq "| \`${repo}\` | Merge queue" "$REPO_ROOT/standards/ci-standards.md" \
      || { echo "${repo} is listed but not recorded in ci-standards.md §2"; return 1; }
  done < <(bash -c 'source "'"$REPO_ROOT"'/scripts/lib/codeql-advanced.sh"; printf "%s\n" "${CODEQL_ADVANCED_EXCEPTIONS[@]}"')
}
