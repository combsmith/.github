#!/usr/bin/env bats
# Template-guard for the SonarCloud token handling in
# standards/workflows/sonarcloud.yml (#1390, #1392).
#
# #1392 — SONAR_TOKEN must never sit in a job- or workflow-level `env:`, where
#   every step (including any build/test step an adopting repo adds to run the
#   checked-out code) inherits it. Only the token gate step and the two scan
#   steps may reference the secret.
#
# #1390 — the `SonarCloud` job is a required check. When the token is
#   unavailable it may only pass as an explicit bootstrap (the SONAR_BOOTSTRAP
#   repo variable) or on a same-repo run (the repo has no token yet); a fork
#   pull request without the token must FAIL instead of passing with both scan
#   steps skipped.
#
# The gate's behaviour is tested by extracting its `run:` script with yq and
# executing it, so the test exercises the shipped code, not a copy of it.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
WF="${REPO_ROOT}/standards/workflows/sonarcloud.yml"
SCAN_ACTION='SonarSource/sonarqube-scan-action@'

setup() {
  command -v yq >/dev/null || { echo "yq (mikefarah) is required"; return 1; }
  GATE_SCRIPT="${BATS_TEST_TMPDIR}/gate.sh"
  GATE_OUT="${BATS_TEST_TMPDIR}/gate.out"
}

# Run the token gate step's script with the given SONAR_TOKEN, SONAR_BOOTSTRAP,
# event name and PR head repo (base repo is fixed at combsmith/example).
run_gate() {
  yq -e '.jobs.sonarcloud.steps[] | select(.id == "token") | .run' "$WF" > "$GATE_SCRIPT"
  : > "$GATE_OUT"
  run env -i PATH="$PATH" GITHUB_OUTPUT="$GATE_OUT" \
    SONAR_TOKEN="$1" SONAR_BOOTSTRAP="$2" EVENT_NAME="$3" HEAD_REPO="$4" \
    BASE_REPO="combsmith/example" bash -e "$GATE_SCRIPT"
}

@test "SONAR_TOKEN is not in any job-level or workflow-level env (#1392)" {
  [ "$(yq '.env.SONAR_TOKEN // "absent"' "$WF")" = "absent" ]
  [ "$(yq '[.jobs[] | select(.env.SONAR_TOKEN != null)] | length' "$WF")" = "0" ]
}

@test "only the token gate and the scan steps reference secrets.SONAR_TOKEN (#1392)" {
  local total allowed bad
  total="$(grep -c 'secrets\.SONAR_TOKEN' "$WF")"
  allowed="$(yq '[.jobs[].steps[]
                  | select((.env.SONAR_TOKEN // "") | test("secrets\.SONAR_TOKEN"))
                  | select(.id == "token" or ((.uses // "") | test("^SonarSource/sonarqube-scan-action@")))]
                 | length' "$WF")"
  bad="$(yq '[.jobs[].steps[]
              | select([.. | select(tag == "!!str") | test("secrets\.SONAR_TOKEN")] | any)
              | select((.id == "token" or ((.uses // "") | test("^SonarSource/sonarqube-scan-action@"))) | not)
              | (.name // .id // .uses)] | join(", ")' "$WF")"
  [ -z "$bad" ] || { echo "steps outside the allow-list read SONAR_TOKEN: $bad"; return 1; }
  # gate + scan + retry, and no other textual reference anywhere in the file.
  [ "$allowed" = "3" ] || { echo "expected 3 allowed references, found $allowed"; return 1; }
  [ "$total" = "3" ] || { echo "expected 3 secrets.SONAR_TOKEN references, found $total"; return 1; }
}

@test "both scan steps are conditioned on the gate's present output (#1390)" {
  local n
  n="$(yq "[.jobs.sonarcloud.steps[]
            | select((.uses // \"\") | test(\"^${SCAN_ACTION}\"))
            | select((.if // \"\") | test(\"steps\\.token\\.outputs\\.present == 'true'\"))]
           | length" "$WF")"
  [ "$n" = "2" ] || { echo "expected scan + retry gated on steps.token.outputs.present, found $n"; return 1; }
}

@test "gate: token present -> analysis runs" {
  run_gate "tok" "" "pull_request" "someone/fork"
  [ "$status" -eq 0 ]
  grep -qx 'present=true' "$GATE_OUT"
}

@test "gate: fork pull request without the token FAILS the required check (#1390)" {
  run_gate "" "" "pull_request" "someone/fork"
  [ "$status" -ne 0 ]
  grep -qx 'present=false' "$GATE_OUT"
  [[ "$output" == *"::error"* ]]
}

@test "gate: pull request with a missing head repo (deleted fork) fails closed" {
  run_gate "" "" "pull_request" ""
  [ "$status" -ne 0 ]
}

@test "gate: explicit SONAR_BOOTSTRAP=true passes without analysis, even for a fork" {
  run_gate "" "true" "pull_request" "someone/fork"
  [ "$status" -eq 0 ]
  grep -qx 'present=false' "$GATE_OUT"
  [[ "$output" == *"::notice"* ]]
}

@test "gate: SONAR_BOOTSTRAP must be exactly 'true'" {
  run_gate "" "yes" "pull_request" "someone/fork"
  [ "$status" -ne 0 ]
}

@test "gate: same-repo run without the token passes with a warning (day-0 repo)" {
  run_gate "" "" "push" ""
  [ "$status" -eq 0 ]
  grep -qx 'present=false' "$GATE_OUT"
  [[ "$output" == *"::warning"* ]]
  run_gate "" "" "pull_request" "combsmith/example"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning"* ]]
}

@test "the gate never prints the token" {
  run_gate "s3cr3t-value" "" "push" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"s3cr3t-value"* ]]
  if grep -q 's3cr3t-value' "$GATE_OUT"; then echo "token written to GITHUB_OUTPUT"; return 1; fi
}

@test "the required-check job name is unchanged" {
  [ "$(yq '.jobs.sonarcloud.name' "$WF")" = "SonarCloud" ]
}
