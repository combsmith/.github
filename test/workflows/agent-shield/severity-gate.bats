#!/usr/bin/env bats
# combsmith/.github#1436: the AgentShield job must fail at the configured
# min-severity, using the scanner's JSON report rather than its exit code.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/agent-shield-reusable.yml"

setup() {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.github/scripts/agent-shield/lib/severity-gate.sh"
  REPORT="$BATS_TEST_TMPDIR/report.json"
}

# report_with SEVERITY... — writes a report with one finding per severity.
report_with() {
  local sev findings="[]"
  for sev in "$@"; do
    findings=$(jq -c --arg s "$sev" \
      '. + [{id: "x", severity: $s, category: "misconfiguration", title: ($s + " finding"),
             description: "why it matters", file: "CLAUDE.md", line: 3,
             evidence: "EVIDENCE-VALUE", fix: {description: "fix it", auto: false}}]' <<<"$findings")
  done
  jq -n --argjson f "$findings" \
    '{timestamp: "2026-10-30T00:00:00.000Z", targetPath: "/repo", findings: $f,
      score: {grade: "A", numericScore: 100},
      summary: {totalFindings: ($f | length), filesScanned: 2, autoFixable: 0}}' >"$REPORT"
}

@test "a high finding fails at the default threshold" {
  report_with high
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::AgentShield: 1 finding(s) at or above high"* ]]
  [[ "$output" == *"[HIGH] high finding (CLAUDE.md:3)"* ]]
}

@test "a critical finding fails at every threshold" {
  report_with critical
  local t
  for t in critical high medium low info; do
    run agent_shield_severity_gate "$t" "$REPORT"
    [ "$status" -eq 1 ]
  done
}

@test "a finding below the threshold passes" {
  report_with medium low info
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no findings at or above high (3 reported)"* ]]
}

@test "the threshold is inclusive at each level" {
  local pairs=("critical high" "high medium" "medium low" "low info") pair
  for pair in "${pairs[@]}"; do
    report_with "${pair% *}"
    run agent_shield_severity_gate "${pair% *}" "$REPORT"
    [ "$status" -eq 1 ]
    report_with "${pair#* }"
    run agent_shield_severity_gate "${pair% *}" "$REPORT"
    [ "$status" -eq 0 ]
  done
  report_with info
  run agent_shield_severity_gate info "$REPORT"
  [ "$status" -eq 1 ]
}

@test "a clean report passes" {
  report_with
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(0 reported)"* ]]
}

@test "findings are listed most severe first and evidence is not printed" {
  report_with high critical
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[CRITICAL]"*"[HIGH]"* ]]
  [[ "$output" != *"EVIDENCE-VALUE"* ]]
}

@test "an unknown threshold fails, even with a clean report" {
  report_with
  local t
  for t in "" HIGH severe "high "; do
    run agent_shield_severity_gate "$t" "$REPORT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"min-severity must be one of"* ]]
  done
}

@test "a missing, empty or non-JSON report fails" {
  run agent_shield_severity_gate high "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 1 ]
  : >"$REPORT"
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 1 ]
  echo 'npm warn something' >"$REPORT"
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::AgentShield:"* ]]
}

@test "stray output around the report fails" {
  report_with
  cp "$REPORT" "$BATS_TEST_TMPDIR/one.json"
  cat "$BATS_TEST_TMPDIR/one.json" "$BATS_TEST_TMPDIR/one.json" >"$REPORT"
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot trust the scan report"* ]]
}

@test "a report that is off-schema fails" {
  local doc
  for doc in \
    '[]' \
    '{}' \
    '{"summary":{"totalFindings":0}}' \
    '{"findings":{},"summary":{"totalFindings":0}}' \
    '{"findings":[]}' \
    '{"findings":[],"summary":{"totalFindings":1}}' \
    '{"findings":["high"],"summary":{"totalFindings":1}}' \
    '{"findings":[{"title":"no severity"}],"summary":{"totalFindings":1}}' \
    '{"findings":[{"severity":"severe"}],"summary":{"totalFindings":1}}' \
    '{"findings":[{"severity":3}],"summary":{"totalFindings":1}}'; do
    printf '%s\n' "$doc" >"$REPORT"
    run agent_shield_severity_gate info "$REPORT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot trust the scan report"* ]]
  done
}

@test "finding text cannot produce workflow commands or break out of its line" {
  jq -n '{findings: [{severity: "high",
      title: "a\n::error::forged ##[stop-commands]x :::y",
      description: "\u001b[31m##[group]z\r\n::warning::w",
      file: "x\n::notice::f", line: 1}],
    summary: {totalFindings: 1}}' >"$REPORT"
  run agent_shield_severity_gate high "$REPORT"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^[[:space:]]*::' <<<"$output")" -eq 1 ]
  [[ "${lines[0]}" == "::error::AgentShield: 1 finding(s) at or above high" ]]
  [[ "$output" != *"##["* ]]
  [[ "$output" != *"::"*"forged"* ]]
  [[ "$output" != *$'\033'* ]]
  [ "${#lines[@]}" -eq 3 ]
}

# --- The reusable's real steps, against a stubbed scanner ---

# run_job_steps STUB_EXIT REPORT_JSON [THRESHOLD] — runs the scan and gate steps
# in a fake checkout, with a stub npx that prints REPORT_JSON and exits STUB_EXIT.
run_job_steps() {
  local stub_exit="$1" report_json="$2" threshold="${3:-high}"
  local tmp="$BATS_TEST_TMPDIR" scan gate
  scan=$(yq '.jobs["agent-shield"].steps[] | select(.name == "AgentShield Security Scan") | .run' "$WORKFLOW")
  gate=$(yq '.jobs["agent-shield"].steps[] | select(.name == "Enforce AgentShield severity threshold") | .run' "$WORKFLOW")
  [ -n "$scan" ] && [ "$scan" != "null" ]
  [ -n "$gate" ] && [ "$gate" != "null" ]

  mkdir -p "$tmp/bin" "$tmp/work" "$tmp/runner-temp"
  ln -sfn "$REPO_ROOT" "$tmp/work/.agent-shield-tooling"
  printf '%s\n' "$report_json" >"$tmp/stub-report.json"
  cat >"$tmp/bin/npx" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$tmp/npx.args"
cat "$tmp/stub-report.json"
exit $stub_exit
STUB
  chmod +x "$tmp/bin/npx"
  printf '%s\n' "$scan" >"$tmp/scan.sh"
  printf '%s\n' "$gate" >"$tmp/gate.sh"

  # Each step runs the way the runner runs it: its own `bash -e`, stopping the job.
  run env RUNNER_TEMP="$tmp/runner-temp" AS_VERSION=1.4.0 AS_SEVERITY="$threshold" \
    PATH="$tmp/bin:$PATH" bash -c \
    'cd "$1/work" && bash -e "$1/scan.sh" && bash -e "$1/gate.sh"' _ "$tmp"
}

REPORT_HIGH='{"findings":[{"severity":"high","title":"t","description":"d","file":"f"}],"summary":{"totalFindings":1}}'
REPORT_CRITICAL='{"findings":[{"severity":"critical","title":"t","description":"d","file":"f"}],"summary":{"totalFindings":1}}'
REPORT_CLEAN='{"findings":[],"summary":{"totalFindings":0}}'

@test "job: the scanner exits 0 with a high finding, and the job still fails" {
  run_job_steps 0 "$REPORT_HIGH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 finding(s) at or above high"* ]]
}

@test "job: the scanner exits 2 for a critical finding, and the gate reports it" {
  run_job_steps 2 "$REPORT_CRITICAL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[CRITICAL]"* ]]
}

@test "job: a clean scan passes" {
  run_job_steps 0 "$REPORT_CLEAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no findings at or above high"* ]]
}

@test "job: a scanner failure stops the job with the scanner's exit code" {
  run_job_steps 4 "$REPORT_CLEAN"
  [ "$status" -eq 4 ]
  [[ "$output" == *"AgentShield scanner failed (exit 4)"* ]]
}

@test "job: a scanner that prints no report fails" {
  run_job_steps 0 ""
  [ "$status" -eq 1 ]
}

@test "job: the scan keeps --ignore-scripts and asks for JSON at the threshold" {
  run_job_steps 0 "$REPORT_CLEAN" medium
  [ "$status" -eq 0 ]
  local args
  args=$(cat "$BATS_TEST_TMPDIR/npx.args")
  [[ "$args" == *"--ignore-scripts"* ]]
  [[ "$args" == *"--min-severity medium"* ]]
  [[ "$args" == *"--format json"* ]]
}

@test "reusable: the gate tooling comes from the reusable's own commit, after the scan" {
  local names
  names=$(yq -r '.jobs["agent-shield"].steps[].name // "checkout"' "$WORKFLOW")
  [ "$(sed -n 2p <<<"$names")" = "AgentShield Security Scan" ]
  [ "$(sed -n 3p <<<"$names")" = "Checkout AgentShield gate tooling" ]
  [ "$(sed -n 4p <<<"$names")" = "Enforce AgentShield severity threshold" ]
  local step='.jobs["agent-shield"].steps[] | select(.name == "Checkout AgentShield gate tooling") | .with'
  # shellcheck disable=SC2016 # a literal GitHub expression, not a shell expansion
  [ "$(yq -r "$step.ref" "$WORKFLOW")" = '${{ job.workflow_sha }}' ]
  [ "$(yq -r "$step.persist-credentials" "$WORKFLOW")" = "false" ]
  [ "$(yq -r "$step.sparse-checkout" "$WORKFLOW")" = ".github/scripts/agent-shield" ]
}
