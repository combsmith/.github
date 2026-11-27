#!/usr/bin/env bats
# Telemetry-gap guards of the weekly compliance audit workflow (#1616).
#
# Audit run 46072704625 read no Dependabot count on any repo (token without
# Dependabot alerts read) and `analyze` ran without the compliance report, both
# silently. This suite pins the guards, STATICALLY (it parses the workflow):
#   - health-survey probes the alert endpoints before collecting, and fails the
#     job — after the report output is written — when one is unreadable;
#   - analyze writes the health report whenever the survey produced one (also
#     from a survey failed by the preflight), checks both inputs, fails fast
#     when it has neither, and hands their status to the prompt.
# It cannot prove GitHub exposes a failed job's outputs; only a live run can.
#
# Run: bats test/workflows/compliance-audit/telemetry-inputs.bats   (needs python3 + PyYAML)

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
WF="$REPO_ROOT/.github/workflows/compliance-audit-and-improvement.yml"

# step <job> <step-id-or-name> <field> — print a step field ('' when absent),
# exit 3 when the step does not exist. `index` prints its position.
step() {
  python3 - "$WF" "$@" <<'PY'
import sys, yaml
wf, job, key, field = sys.argv[1:5]
steps = yaml.safe_load(open(wf))["jobs"][job]["steps"]
for i, s in enumerate(steps):
    if s.get("id") == key or s.get("name") == key:
        if field == "index":
            print(i)
        else:
            v = s.get(field, "")
            print(v if isinstance(v, str) else str(v).lower() if isinstance(v, bool) else yaml.safe_dump(v))
        sys.exit(0)
sys.exit(3)
PY
}

setup() {
  python3 -c 'import yaml' 2>/dev/null || { echo "PyYAML is required" >&2; return 1; }
}

# ── health-survey ────────────────────────────────────────────────────────────

@test "health-survey: a preflight probes the alert endpoints before collection" {
  run step health-survey preflight run
  [ "$status" -eq 0 ]
  [[ "$output" == *"source scripts/lib/health-alerts.sh"* ]]
  [[ "$output" == *"health_alert_preflight"* ]]
  [[ "$output" == *'unreadable='*'$GITHUB_OUTPUT'* ]]
  pre=$(step health-survey preflight index)
  col=$(step health-survey collect index)
  [ "$pre" -lt "$col" ]
}

@test "health-survey: the preflight itself never stops the telemetry collection" {
  run step health-survey preflight run
  [[ "$output" != *"exit 1"* ]]
  run step health-survey collect if
  [ -z "$output" ]
}

@test "health-survey: an unreadable endpoint fails the job after the report is written" {
  run step health-survey fail-on-unreadable-alerts if
  [ "$status" -eq 0 ]
  [[ "$output" == *"steps.preflight.outputs.unreadable != ''"* ]]
  run step health-survey fail-on-unreadable-alerts run
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"exit 1"* ]]
  col=$(step health-survey collect index)
  fail=$(step health-survey fail-on-unreadable-alerts index)
  [ "$col" -lt "$fail" ]
}

# ── analyze ──────────────────────────────────────────────────────────────────

@test "analyze: the health report is written whenever the survey produced one" {
  run step analyze "Write health survey report" if
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs.health-survey.outputs.report != ''"* ]]
}

@test "analyze: an input check runs before the model and fails fast with neither input" {
  run step analyze input_status run
  [ "$status" -eq 0 ]
  [[ "$output" == *"source scripts/lib/analysis-inputs.sh"* ]]
  [[ "$output" == *"compliance-report/findings.json"* ]]
  [[ "$output" == *"health-survey.json"* ]]
  [[ "$output" == *"exit 1"* ]]
  run step analyze input_status env
  [[ "$output" == *"needs.audit.result"* ]]
  [[ "$output" == *"needs.health-survey.result"* ]]
  inp=$(step analyze input_status index)
  model=$(step analyze "Run Claude Code for combined analysis" index)
  [ "$inp" -lt "$model" ]
}

@test "analyze: a failed download is reported by the input check, not a silent stop" {
  run step analyze "Download compliance audit report" continue-on-error
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run step analyze "Run Claude Code for combined analysis" with
  [[ "$output" == *"steps.input_status.outputs.compliance_report"* ]]
  [[ "$output" == *"steps.input_status.outputs.health_survey"* ]]
}
