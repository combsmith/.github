#!/usr/bin/env bats
# Tests for check_declared_required_checks in scripts/compliance-audit.sh
# (combsmith/.github#1410).
#
# A repo may declare extra required status checks in .github/required-checks.json;
# apply-rulesets.sh merges them into `code-quality`. The audit enforces the
# declaration in the reverse direction: a declared check the live code-quality
# ruleset does not enforce (absent, or pinned to a different app) is an error.
# Fail closed: an unreadable or invalid declaration is a finding, never a pass.
# A repo that declares nothing (HTTP 404) produces no finding.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
CQ_CHECKS="$(jq -c '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[]]' \
  "$REPO_ROOT/standards/rulesets/code-quality.json")"
MUT='{"version":1,"required_status_checks":[{"context":"mutation (all)","integration_id":15368}]}'
CQ_RULESETS='[{"id":102,"name":"code-quality"}]'

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/declared-checks.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() { rm -rf "$TEST_TMP"; }

# _run <declaration|NONE|FAIL> <live_checks_json> [rulesets_json]
# Mock gh serves the declaration (NONE → HTTP 404, FAIL → HTTP 500) and a live
# code-quality ruleset (id 102) whose required_status_checks are <live_checks_json>,
# then runs check_declared_required_checks and prints findings.json.
_run() {
  local declared="$1" live="$2" rulesets="${3:-$CQ_RULESETS}" src_dir="${4:-$REPO_ROOT/standards/rulesets}"
  printf '%s' "$declared" > "$TEST_TMP/declared"
  printf '%s' "$live" > "$TEST_TMP/live"
  cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
path=""
for a in "\$@"; do
  case "\$a" in --*|-H|api|Accept:*) : ;; *) path="\$a" ;; esac
done
case "\$path" in
  */contents/.github/required-checks.json)
    d="\$(cat "$TEST_TMP/declared")"
    [ "\$d" = "NONE" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [ "\$d" = "FAIL" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    printf '%s' "\$d" ;;
  */rulesets/102)
    [ "\$(cat "$TEST_TMP/live")" = "FAIL" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    printf '{"id":102,"name":"code-quality","rules":[{"type":"required_status_checks","parameters":{"required_status_checks":%s}}]}' "\$(cat "$TEST_TMP/live")" ;;
  *) echo '[]' ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" RULESETS_JSON="$rulesets" RULESETS_SRC_DIR="$src_dir" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_declared_required_checks "demo-repo" "$RULESETS_JSON"
    cat "$REPORT_DIR/findings.json"
  '
}

_with_mutation() { jq -cn --argjson c "$CQ_CHECKS" '$c + [{"context":"mutation (all)","integration_id":15368}]'; }

@test "no declaration (404) → no finding" {
  run _run NONE "$CQ_CHECKS"
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 0 ]
}

@test "every declared check live with its app → no finding" {
  run _run "$MUT" "$(_with_mutation)"
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 0 ]
}

@test "a declared check missing from live code-quality → error naming the context" {
  run _run "$MUT" "$CQ_CHECKS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].check' <<< "$output")" = "declared-required-check-missing-mutation-all" ]
  [ "$(jq -r '.[0].severity' <<< "$output")" = "error" ]
  [[ "$(jq -r '.[0].detail' <<< "$output")" == *"mutation (all)"*"apply-rulesets.sh"* ]]
}

@test "a declared check live under a different app (or none) → error" {
  run _run "$MUT" "$(jq -cn --argjson c "$CQ_CHECKS" '$c + [{"context":"mutation (all)"}]')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].check' <<< "$output")" = "declared-required-check-missing-mutation-all" ]
  [[ "$(jq -r '.[0].detail' <<< "$output")" == *"15368"* ]]
}

@test "an unreadable declaration → fail-closed error" {
  run _run FAIL "$CQ_CHECKS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].check' <<< "$output")" = "declared-required-checks-unreadable" ]
  [ "$(jq -r '.[0].severity' <<< "$output")" = "error" ]
  grep -qxF demo-repo "$TEST_TMP/inconclusive-repos.txt"
}

@test "an unreadable codified source → source-invalid error and repo marked inconclusive" {
  mkdir -p "$TEST_TMP/badsrc"
  printf 'not json' > "$TEST_TMP/badsrc/code-quality.json"
  run _run "$MUT" "$CQ_CHECKS" "$CQ_RULESETS" "$TEST_TMP/badsrc"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].check' <<< "$output")" = "declared-required-checks-source-invalid" ]
  grep -qxF demo-repo "$TEST_TMP/inconclusive-repos.txt"
}

@test "an unfetchable live code-quality ruleset → no finding here, repo marked inconclusive" {
  # check_ruleset_contents reports the unfetchable ruleset; this check must not
  # let an open missing-check issue close on a comparison that never ran.
  run _run "$MUT" FAIL
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 0 ]
  grep -qxF demo-repo "$TEST_TMP/inconclusive-repos.txt"
}

@test "an invalid declaration → error naming the problem" {
  run _run '{"version":1,"required_status_checks":[{"context":"x"}]}' "$CQ_CHECKS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].check' <<< "$output")" = "declared-required-checks-invalid" ]
  [[ "$(jq -r '.[0].detail' <<< "$output")" == *"integration_id"* ]]
}

@test "no code-quality ruleset but checks declared → no finding here, repo marked inconclusive" {
  # check_rulesets reports missing-code-quality; the declared checks cannot be
  # verified, so an open declared-required-check-missing-* issue must stay open.
  run _run "$MUT" "$CQ_CHECKS" '[]'
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 0 ]
  grep -qxF demo-repo "$TEST_TMP/inconclusive-repos.txt"
}

@test "no code-quality ruleset and nothing declared → silent, repo NOT marked inconclusive" {
  # Marking every repo without code-quality inconclusive would hold back issue
  # auto-closure fleet-wide; only a repo with declared checks has anything unverified.
  run _run NONE "$CQ_CHECKS" '[]'
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 0 ]
  ! grep -qxF demo-repo "$TEST_TMP/inconclusive-repos.txt" 2>/dev/null
}

@test "a declared codified context (CodeQL) with a different app → no finding (applier keeps the codified entry)" {
  run _run '{"version":1,"required_status_checks":[{"context":"CodeQL","integration_id":15368}]}' "$CQ_CHECKS"
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 0 ]
}

@test "an empty declaration → invalid finding and repo marked inconclusive" {
  run _run ' ' "$CQ_CHECKS"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].check' <<< "$output")" = "declared-required-checks-invalid" ]
  [ -s "$TEST_TMP/inconclusive-repos.txt" ]
  grep -qxF demo-repo "$TEST_TMP/inconclusive-repos.txt"
}
