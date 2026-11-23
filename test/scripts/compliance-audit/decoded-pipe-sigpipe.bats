#!/usr/bin/env bats
# Regression tests for the "echo: write error: Broken pipe" abort in
# scripts/compliance-audit.sh (#1343).
#
# Every scheduled audit from 2026-10-23 onward died with
#   scripts/compliance-audit.sh: line 607: echo: write error: Broken pipe
# in check_reusable_workflows_disabled. The cause was
#   on_line=$(echo "$decoded" | grep -m1 '^on:')
# `grep -m1` / `grep -q` / `awk '… exit'` stop reading at the first match, so
# echo's next chunked write gets EPIPE (the Actions runner ignores SIGPIPE).
# Under `set -euo pipefail` that failing pipeline aborts the whole audit when
# it is a bare assignment, and silently flips the result when it is an `if`
# condition. These tests run the REAL script under the runner's shell options
# with SIGPIPE ignored, and feed it content large enough to make the race
# deterministic.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/compliance-audit.sh"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/sigpipe.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() { rm -rf "$TEST_TMP"; }

# _write_workflow <header>: write <header> followed by ~1 MiB of comment
# padding as the mock workflow, base64-encoded the way the contents API
# returns it. The padding goes AFTER the header, so an early-exit reader
# matches in the first chunk and the writer is still writing.
_write_workflow() {
  {
    printf '%s\n' "$1"
    local i
    for i in $(seq 1 16000); do
      printf '# padding line %05d ..........................................\n' "$i"
    done
  } | base64 > "$TEST_TMP/content.b64"
}

# Mock gh: workflow listing → big.yml, file content → the b64 fixture,
# workflow state → active. Arguments after the path (--jq …) are ignored;
# the mock returns already-filtered values.
_install_gh_mock() {
  cat > "$MOCK_BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$2" in
  */contents/.github/workflows) echo "big.yml" ;;
  */contents/.github/workflows/big.yml) cat "$TEST_TMP/content.b64" ;;
  */actions/workflows/big.yml) echo "active" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"
}

# _run_check <function>: source the real audit under the CI shell options
# (bash -e from the workflow step + the script's own set -euo pipefail) with
# SIGPIPE ignored like the Actions runner, run <function> on a fake repo,
# then print findings.json.
_run_check() {
  _install_gh_mock
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" FN="$1" SCRIPT="$SCRIPT" \
    bash -c '
      trap "" PIPE
      set -euo pipefail
      echo "[]" > "$REPORT_DIR/findings.json"
      # shellcheck disable=SC1090
      source "$SCRIPT"
      set -euo pipefail
      "$FN" "demo-repo"
      echo "CHECK_COMPLETED"
      cat "$REPORT_DIR/findings.json"
    '
}

@test "large pure-reusable workflow: check_reusable_workflows_disabled completes (no broken-pipe abort)" {
  _write_workflow $'name: big\non:\n  workflow_call:\n    inputs:\n      x:\n        type: string\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []'
  run --separate-stderr _run_check check_reusable_workflows_disabled
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_COMPLETED"* ]]
  [[ "$stderr" != *"Broken pipe"* ]]
  # Classification is still correct: workflow_call-only, state active → flagged.
  [[ "$output" == *"reusable-not-disabled-manually-big.yml"* ]]
  [[ "$output" == *"reusable-naming-big.yml"* ]]
}

@test "large hybrid workflow (workflow_call + push) is still exempt" {
  _write_workflow $'name: big\non:\n  workflow_call:\n  push:\n    branches: [main]\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []'
  run --separate-stderr _run_check check_reusable_workflows_disabled
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_COMPLETED"* ]]
  [[ "$output" != *"reusable-not-disabled-manually"* ]]
}

@test "workflow with no top-level on: line does not abort the audit" {
  _write_workflow $'name: big\n"on":\n  push:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []'
  run --separate-stderr _run_check check_reusable_workflows_disabled
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_COMPLETED"* ]]
  [[ "$output" != *"reusable-not-disabled-manually"* ]]
}

@test "large workflow with top-level permissions: no false missing-permissions finding" {
  _write_workflow $'name: big\non:\n  push:\npermissions:\n  contents: read\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []\n  b:\n    runs-on: ubuntu-latest\n    steps: []'
  run --separate-stderr _run_check check_workflow_permissions
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK_COMPLETED"* ]]
  [[ "$stderr" != *"Broken pipe"* ]]
  [[ "$output" != *"big.yml"* ]]
}

@test "static guard: no \$decoded pipeline into an early-exit reader" {
  # grep -q / grep -m / awk …exit / | head stop reading early and EPIPE the
  # writer. Use a here-string (<<<\"\$decoded\") instead.
  run grep -nE '(\$decoded|printf.*decoded).*\|.*(grep -[A-Za-z]*[qm]|awk .*exit|head)' "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
