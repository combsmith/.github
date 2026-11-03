#!/usr/bin/env bats
# ci.yml's Agent Security Scan job must fail on a high-severity finding.
#
# The scanner's --min-severity only filters its report, and it exits non-zero
# only for critical findings, so the job enforces the threshold from the JSON
# report with the shared gate in .github/scripts/agent-shield/lib/severity-gate.sh
# (the same gate the AgentShield reusable uses, #1436). These tests run the job's
# real steps against a stubbed scanner.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

# job_step NAME — prints the run: script of the agent-security step called NAME.
job_step() {
  yq -r ".jobs[\"agent-security\"].steps[] | select(.name == \"$1\") | .run" "$TT_WORKFLOW"
}

# run_job_steps STUB_EXIT REPORT_JSON — runs the scan and gate steps from the repo
# root, with a stub npx that prints REPORT_JSON and exits STUB_EXIT.
run_job_steps() {
  local stub_exit="$1" report_json="$2"
  local tmp="$BATS_TEST_TMPDIR" scan gate severity
  scan=$(job_step "Run AgentShield")
  gate=$(job_step "Enforce AgentShield severity threshold")
  severity=$(yq -r '.jobs["agent-security"].env.AGENTSHIELD_MIN_SEVERITY' "$TT_WORKFLOW")
  [ -n "$scan" ] && [ "$scan" != "null" ]
  [ -n "$gate" ] && [ "$gate" != "null" ]

  mkdir -p "$tmp/bin" "$tmp/runner-temp"
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
  # shellcheck disable=SC2016 # expanded by the inner bash, not here
  run env RUNNER_TEMP="$tmp/runner-temp" AGENTSHIELD_MIN_SEVERITY="$severity" \
    PATH="$tmp/bin:$PATH" bash -c \
    'cd "$1" && bash -e "$2/scan.sh" && bash -e "$2/gate.sh"' _ "$TT_REPO_ROOT" "$tmp"
}

finding() {
  printf '{"findings":[{"severity":"%s","title":"t","description":"d","file":"f"}],"summary":{"totalFindings":1}}' "$1"
}

REPORT_CLEAN='{"findings":[],"summary":{"totalFindings":0}}'

@test "agent-security: the job fails at high" {
  [ "$(yq -r '.jobs["agent-security"].env.AGENTSHIELD_MIN_SEVERITY' "$TT_WORKFLOW")" = "high" ]
}

@test "agent-security: the scanner exits 0 with a high finding, and the job still fails" {
  run_job_steps 0 "$(finding high)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 finding(s) at or above high"* ]]
  [[ "$output" == *"[HIGH]"* ]]
}

@test "agent-security: the scanner exits 2 for a critical finding, and the gate reports it" {
  run_job_steps 2 "$(finding critical)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[CRITICAL]"* ]]
}

@test "agent-security: a medium finding passes" {
  run_job_steps 0 "$(finding medium)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no findings at or above high (1 reported)"* ]]
}

@test "agent-security: a clean scan passes" {
  run_job_steps 0 "$REPORT_CLEAN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no findings at or above high (0 reported)"* ]]
}

@test "agent-security: a scanner failure stops the job with the scanner's exit code" {
  run_job_steps 4 "$REPORT_CLEAN"
  [ "$status" -eq 4 ]
  [[ "$output" == *"AgentShield scanner failed (exit 4)"* ]]
}

@test "agent-security: a scanner that prints no report fails" {
  run_job_steps 0 ""
  [ "$status" -eq 1 ]
}

@test "agent-security: the scan keeps --ignore-scripts and asks for JSON at the threshold" {
  run_job_steps 0 "$REPORT_CLEAN"
  [ "$status" -eq 0 ]
  local args
  args=$(cat "$BATS_TEST_TMPDIR/npx.args")
  [[ "$args" == *"--ignore-scripts"* ]]
  [[ "$args" == *"--min-severity high"* ]]
  [[ "$args" == *"--format json"* ]]
}

@test "agent-security: the gate step uses the shared severity gate" {
  local gate
  gate=$(job_step "Enforce AgentShield severity threshold")
  [[ "$gate" == *". .github/scripts/agent-shield/lib/severity-gate.sh"* ]]
  # shellcheck disable=SC2016 # a literal string in the step script
  [[ "$gate" == *'agent_shield_severity_gate "$AGENTSHIELD_MIN_SEVERITY"'* ]]
}
