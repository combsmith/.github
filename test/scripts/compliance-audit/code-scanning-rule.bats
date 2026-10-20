#!/usr/bin/env bats
# Tests for check_code_scanning_rule in scripts/compliance-audit.sh and the pure
# floor comparison it uses (cs_floor_shortfall, scripts/lib/code-scanning.sh).
#
# The standard (standards/github-settings.md#code-scanning-merge-protection-all-repositories)
# requires a `code_scanning` rule on every default branch at or above the floor
# codified in standards/rulesets/code-quality.json: CodeQL,
# security_alerts_threshold `medium_or_higher`, alerts_threshold `errors`.
#
# Semantics pinned here:
#   - The floor is a MINIMUM. A stricter threshold (`all`) passes — it must never
#     be reported, or the remediation would "fix" it down.
#   - Only the rules that APPLY to the branch count, from any active ruleset
#     (GET rules/branches/{branch}); several rulesets layer, strictest wins.
#   - A missing rule, a weaker threshold or an unknown value is a finding.
#   - Fail closed: an unreadable read or codified source is a finding, never a pass.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# The floor, read straight from the source of truth so the fixtures stay in
# lockstep with what the audit compares against.
CS_FLOOR="$(jq -c '[.rules[] | select(.type=="code_scanning") | .parameters.code_scanning_tools[]]' \
  "$REPO_ROOT/standards/rulesets/code-quality.json")"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/code-scanning-rule.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _cs_rule <security_alerts_threshold> <alerts_threshold> [tool]
# One rules/branches entry: a code_scanning rule from a ruleset.
_cs_rule() {
  jq -cn --arg s "$1" --arg a "$2" --arg t "${3:-CodeQL}" \
    '{type:"code_scanning",ruleset_source_type:"Repository",ruleset_id:1,
      parameters:{code_scanning_tools:[{tool:$t,security_alerts_threshold:$s,alerts_threshold:$a}]}}'
}

# _run_check <branch_rules_body> [rulesets_src_dir]
# Mock `gh` serves <branch_rules_body> for rules/branches/main (the literal
# FETCHFAIL makes the read fail), sources the audit, runs
# check_code_scanning_rule, and prints findings.json then the inconclusive list.
_run_check() {
  local body="$1" src="${2:-$REPO_ROOT/standards/rulesets}"
  printf '%s' "$body" > "$TEST_TMP/branch-rules.json"
  cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
path=""
for a in "\$@"; do
  case "\$a" in --*|api) : ;; *) path="\$a" ;; esac
done
case "\$path" in
  */rules/branches/main)
    if [ "\$(cat "$TEST_TMP/branch-rules.json")" = "FETCHFAIL" ]; then
      echo "gh: Server Error (HTTP 500)" >&2; exit 1
    fi
    cat "$TEST_TMP/branch-rules.json"
    ;;
  *) echo '[]' ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" RULESETS_SRC_DIR="$src" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_code_scanning_rule "demo-repo" "main"
    cat "$REPORT_DIR/findings.json"
    echo "INCONCLUSIVE:"
    cat "$REPORT_DIR/inconclusive-repos.txt" 2>/dev/null || true
  '
}

# ---------------------------------------------------------------------------
# The codified floor itself
# ---------------------------------------------------------------------------
@test "code-quality.json codifies CodeQL at medium_or_higher / errors" {
  [ "$CS_FLOOR" = '[{"tool":"CodeQL","security_alerts_threshold":"medium_or_higher","alerts_threshold":"errors"}]' ]
}

# ---------------------------------------------------------------------------
# At or above the floor → no finding
# ---------------------------------------------------------------------------
@test "rule exactly at the floor → no finding" {
  run _run_check "[$(_cs_rule medium_or_higher errors)]"
  [ "$status" -eq 0 ]
  [[ "$output" != *"code-scanning-rule"* ]]
}

@test "stricter security threshold (all) → passes, never reported as drift" {
  run _run_check "[$(_cs_rule all errors)]"
  [ "$status" -eq 0 ]
  [[ "$output" != *"code-scanning-rule"* ]]
}

@test "stricter alerts threshold (errors_and_warnings, all) → passes" {
  run _run_check "[$(_cs_rule medium_or_higher errors_and_warnings)]"
  [[ "$output" != *"code-scanning-rule"* ]]
  run _run_check "[$(_cs_rule all all)]"
  [[ "$output" != *"code-scanning-rule"* ]]
}

@test "the rule in a repo's own ruleset (not code-quality) counts" {
  # software-factory's shape: its own 'main' ruleset carries the rule at `all`
  # beside pull_request / merge_queue rules; there is no code-quality ruleset.
  rules="[{\"type\":\"pull_request\",\"parameters\":{}},{\"type\":\"merge_queue\",\"parameters\":{}},$(_cs_rule all errors)]"
  run _run_check "$rules"
  [ "$status" -eq 0 ]
  [[ "$output" != *"code-scanning-rule"* ]]
}

@test "two rulesets layer: strictest value per field wins" {
  # Neither entry meets the floor alone; together GitHub enforces both.
  run _run_check "[$(_cs_rule all none),$(_cs_rule none errors)]"
  [ "$status" -eq 0 ]
  [[ "$output" != *"code-scanning-rule"* ]]
}

@test "paginated branch rules (one array per page) are merged" {
  run _run_check "[{\"type\":\"deletion\"}]
[$(_cs_rule medium_or_higher errors)]"
  [ "$status" -eq 0 ]
  [[ "$output" != *"code-scanning-rule"* ]]
}

# ---------------------------------------------------------------------------
# Missing or weaker → a finding naming expected and actual
# ---------------------------------------------------------------------------
@test "no code_scanning rule on the branch → code-scanning-rule-missing (rulesets, error)" {
  run _run_check '[{"type":"pull_request","parameters":{}},{"type":"required_status_checks","parameters":{}}]'
  [ "$status" -eq 0 ]
  [ "$(jq '[.[]|select(.check=="code-scanning-rule-missing")]|length' <<< "${output%%INCONCLUSIVE:*}")" -eq 1 ]
  [ "$(jq -r '.[0].category' <<< "${output%%INCONCLUSIVE:*}")" = "rulesets" ]
  [ "$(jq -r '.[0].severity' <<< "${output%%INCONCLUSIVE:*}")" = "error" ]
  [[ "$output" == *"apply-rulesets.sh --repo combsmith/demo-repo code-quality"* ]]
}

@test "no rules at all on the branch → code-scanning-rule-missing" {
  run _run_check '[]'
  [[ "$output" == *"code-scanning-rule-missing"* ]]
}

@test "a code_scanning rule for another tool only → CodeQL missing" {
  run _run_check "[$(_cs_rule all all Semgrep)]"
  [[ "$output" == *"code-scanning-rule-missing"* ]]
}

@test "GitHub's high_or_higher → weak security_alerts_threshold, expected and actual named" {
  run _run_check "[$(_cs_rule high_or_higher errors)]"
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-scanning-rule-weak-security_alerts_threshold"* ]]
  [[ "$output" == *'`high_or_higher`'* ]]
  [[ "$output" == *'`medium_or_higher`'* ]]
  [[ "$output" != *"code-scanning-rule-weak-alerts_threshold"* ]]
}

@test "alerts_threshold none → weak alerts_threshold only" {
  run _run_check "[$(_cs_rule medium_or_higher none)]"
  [[ "$output" == *"code-scanning-rule-weak-alerts_threshold"* ]]
  [[ "$output" != *"code-scanning-rule-weak-security_alerts_threshold"* ]]
}

@test "both thresholds weak → one finding each" {
  run _run_check "[$(_cs_rule critical none)]"
  [ "$(jq 'length' <<< "${output%%INCONCLUSIVE:*}")" -eq 2 ]
}

@test "an unknown threshold value is read as short of the floor (fail closed)" {
  run _run_check "[$(_cs_rule bogus errors)]"
  [[ "$output" == *"code-scanning-rule-weak-security_alerts_threshold"* ]]
}

# ---------------------------------------------------------------------------
# Fail closed
# ---------------------------------------------------------------------------
@test "branch rules unreadable → finding, and the repo is marked inconclusive" {
  run _run_check "FETCHFAIL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-scanning-rule-unreadable"* ]]
  [[ "${output##*INCONCLUSIVE:}" == *"demo-repo"* ]]
  [[ "$output" != *"code-scanning-rule-missing"* ]]
}

@test "branch rules not an array → unreadable, not a pass" {
  run _run_check '{"message":"Not Found"}'
  [[ "$output" == *"code-scanning-rule-unreadable"* ]]
}

@test "codified source without a code_scanning rule → source-invalid finding" {
  mkdir -p "$TEST_TMP/src"
  jq '.rules |= map(select(.type != "code_scanning"))' \
    "$REPO_ROOT/standards/rulesets/code-quality.json" > "$TEST_TMP/src/code-quality.json"
  run _run_check "[$(_cs_rule all all)]" "$TEST_TMP/src"
  [[ "$output" == *"code-scanning-rule-source-invalid"* ]]
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
@test "check_rulesets runs the code-scanning check on the repo's default branch" {
  run grep -A40 '^check_rulesets() {' "$REPO_ROOT/scripts/compliance-audit.sh"
  [[ "$output" == *'check_code_scanning_rule "$repo" "$default_branch"'* ]]
}

@test "code-scanning findings route to dev-lead:hands-off (rulesets category)" {
  run bash -c 'source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"; category_actor_label rulesets'
  [ "$output" = "dev-lead:hands-off" ]
}
