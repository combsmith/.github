#!/usr/bin/env bats
# Tests for the existing-issue lookup in create_issue_for_finding()
# (scripts/compliance-audit.sh, issue #1385).
#
# A finding title can carry repository-controlled text: the unpinned-actions
# check is `unpinned-actions-<workflow filename>`. The lookup used to splice that
# title into the jq program passed to `gh issue list -q`, so a crafted filename
# could rewrite the selection and hand an arbitrary value to `gh issue edit` /
# `gh issue comment`. These tests pin the fixed contract:
#
#   - the title is compared as DATA (exact string equality), never parsed as jq;
#   - a title containing quotes still finds its own existing issue;
#   - only a plain issue number is ever passed on to issue edit/comment.
#
# The gh mock emulates the real CLI: `issue list --json` emits the fixture array,
# and a `-q`/`--jq` filter (if one is passed) is applied with jq, exactly as gh
# would, so the test exercises whatever program the script builds.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/ftl.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"

  MOCK_ARGS_LOG="$TEST_TMP/gh-args.log"
  : > "$MOCK_ARGS_LOG"
  MOCK_ISSUES_JSON="$TEST_TMP/issues.json"

  cat > "$MOCK_BIN/gh" << 'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_ARGS_LOG"
case "$1 $2" in
  "issue list")
    q="" prev=""
    for a in "$@"; do
      if [ "$prev" = "-q" ] || [ "$prev" = "--jq" ]; then q="$a"; fi
      prev="$a"
    done
    if [ -n "$q" ]; then jq -r "$q" "$MOCK_ISSUES_JSON"; else cat "$MOCK_ISSUES_JSON"; fi
    ;;
  "issue create") echo "https://github.com/combsmith/demo/issues/4242" ;;
  "api")
    case "$*" in
      *"/pulls?"*) echo "0" ;;
      *) : ;;
    esac ;;
  *) : ;;
esac
exit 0
GH
  chmod +x "$MOCK_BIN/gh"
}

teardown() { rm -rf "$TEST_TMP"; }

# _cif <issues-json> <check> : source the audit and run create_issue_for_finding
# for an action-pinning finding with the given check id.
_cif() {
  printf '%s\n' "$1" > "$MOCK_ISSUES_JSON"
  MOCK_ARGS_LOG="$MOCK_ARGS_LOG" MOCK_ISSUES_JSON="$MOCK_ISSUES_JSON" \
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    export MOCK_ARGS_LOG MOCK_ISSUES_JSON
    echo "[]" > "'"$TEST_TMP"'/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    create_issue_for_finding demo action-pinning "$1" error "detail" standards/ci-standards.md
  ' _ "$2" 2>/dev/null
}

@test "#1385: a jq-shaped workflow filename cannot redirect the existing-issue lookup" {
  # Title splices into `select(.title == "<title>")` to make the selection
  # always true and emit an attacker-chosen value instead of a real match.
  local check='unpinned-actions-x"or(true))|{number:999}|select(""!="x.yml'
  _cif '[{"number":12,"title":"Compliance: unpinned-actions-other.yml"}]' "$check"

  # No existing issue has this exact title: nothing is edited or commented on,
  # least of all the injected number; a new issue is created with the literal title.
  ! grep -q '^issue comment' "$MOCK_ARGS_LOG"
  ! grep -q '^issue edit' "$MOCK_ARGS_LOG"
  ! grep -q '999' "$MOCK_ARGS_LOG"
  grep -q '^issue create' "$MOCK_ARGS_LOG"
  grep -qF -- "--title Compliance: $check" "$MOCK_ARGS_LOG"
}

@test "#1385: a title containing a double quote still finds its own existing issue" {
  local check='unpinned-actions-a"b.yml'
  _cif '[{"number":12,"title":"Compliance: unpinned-actions-a\"b.yml"}]' "$check"

  grep -q '^issue comment 12 ' "$MOCK_ARGS_LOG"
  ! grep -q '^issue create' "$MOCK_ARGS_LOG"
}

@test "#1385: a non-numeric existing-issue value is never passed to issue edit/comment" {
  local check='unpinned-actions-ci.yml'
  _cif '[{"number":"https://github.com/other/repo/issues/1","title":"Compliance: unpinned-actions-ci.yml"}]' "$check"

  ! grep -q '^issue comment' "$MOCK_ARGS_LOG"
  ! grep -q '^issue edit' "$MOCK_ARGS_LOG"
  ! grep -q 'other/repo' "$MOCK_ARGS_LOG"
}

@test "#1385: plain titles keep matching the existing issue exactly (no regression)" {
  local check='unpinned-actions-ci.yml'
  _cif '[{"number":7,"title":"Compliance: unpinned-actions-ci.yml.bak"},{"number":8,"title":"Compliance: unpinned-actions-ci.yml"}]' "$check"

  grep -q '^issue comment 8 ' "$MOCK_ARGS_LOG"
  ! grep -q '^issue comment 7 ' "$MOCK_ARGS_LOG"
  ! grep -q '^issue create' "$MOCK_ARGS_LOG"
}
