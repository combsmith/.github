#!/usr/bin/env bats
# Guard: this repo's own .github/workflows/sonarcloud.yml never runs the
# checked-out code with SONAR_TOKEN reachable (#1392), and its required
# `SonarCloud` job does not pass a fork PR it could not analyse (#1390).
#
# The PR / merge-queue revision's Python (pip install + pytest for coverage)
# runs in a separate job that has no secrets at all and hands coverage.xml to
# the `SonarCloud` job as an artifact. SONAR_TOKEN lives only in the env of the
# token gate and the two scan steps, never in a job- or workflow-level `env:`.
#
# Sibling guard for the template other repos adopt:
# test/scripts/standards-templates/sonarcloud-token-gate.bats.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
WF="${REPO_ROOT}/.github/workflows/sonarcloud.yml"

setup() {
  command -v yq >/dev/null || { echo "yq (mikefarah) is required"; return 1; }
  GATE_SCRIPT="${BATS_TEST_TMPDIR}/gate.sh"
  GATE_OUT="${BATS_TEST_TMPDIR}/gate.out"
}

# Run the token gate step's script: SONAR_TOKEN SONAR_BOOTSTRAP EVENT HEAD_REPO.
run_gate() {
  yq -e '.jobs.sonarcloud.steps[] | select(.id == "token") | .run' "$WF" > "$GATE_SCRIPT"
  : > "$GATE_OUT"
  run env -i PATH="$PATH" GITHUB_OUTPUT="$GATE_OUT" \
    SONAR_TOKEN="$1" SONAR_BOOTSTRAP="$2" EVENT_NAME="$3" HEAD_REPO="$4" \
    BASE_REPO="combsmith/.github" bash -e "$GATE_SCRIPT"
}

# Job ids whose steps execute repo code (pip / pytest / python).
jobs_running_repo_code() {
  yq '.jobs | to_entries[]
      | select([.value.steps[] | (.run // "") | test("(^|[[:space:]])(pip3?|pytest|python3?)[[:space:]]")] | any)
      | .key' "$WF"
}

@test "SONAR_TOKEN is not in any job-level or workflow-level env (#1392)" {
  [ "$(yq '.env.SONAR_TOKEN // "absent"' "$WF")" = "absent" ]
  [ "$(yq '[.jobs[] | select(.env.SONAR_TOKEN != null)] | length' "$WF")" = "0" ]
}

@test "the job that runs the checked-out Python has no secrets at all (#1392)" {
  local jobs job
  jobs="$(jobs_running_repo_code)"
  [ -n "$jobs" ] || { echo "no job runs pip/pytest — guard would pass vacuously"; return 1; }
  for job in $jobs; do
    [ "$job" != "sonarcloud" ] || { echo "the SonarCloud scan job runs repo code"; return 1; }
    if yq ".jobs.\"${job}\"" "$WF" | grep -q 'secrets\.'; then
      echo "job '${job}' runs repo code and references a secret"; return 1
    fi
  done
}

@test "only the token gate and the scan steps reference secrets.SONAR_TOKEN (#1392)" {
  local total bad
  total="$(grep -c 'secrets\.SONAR_TOKEN' "$WF")"
  bad="$(yq '[.jobs[].steps[]
              | select([.. | select(tag == "!!str") | test("secrets\.SONAR_TOKEN")] | any)
              | select((.id == "token" or ((.uses // "") | test("^SonarSource/sonarqube-scan-action@"))) | not)
              | (.name // .id // .uses)] | join(", ")' "$WF")"
  [ -z "$bad" ] || { echo "steps outside the allow-list read SONAR_TOKEN: $bad"; return 1; }
  [ "$total" = "3" ] || { echo "expected 3 secrets.SONAR_TOKEN references, found $total"; return 1; }
}

@test "the scan job consumes coverage from the coverage job's artifact" {
  [ "$(yq '.jobs.sonarcloud.needs' "$WF")" = "coverage" ]
  yq -e '.jobs.coverage.steps[] | select((.uses // "") | test("^actions/upload-artifact@"))' "$WF" >/dev/null
  yq -e '.jobs.sonarcloud.steps[] | select((.uses // "") | test("^actions/download-artifact@"))' "$WF" >/dev/null
}

@test "a failed or skipped coverage job fails the SonarCloud check instead of skipping it" {
  # A skipped required job reports success, so the job must run whenever the
  # workflow was not cancelled and fail explicitly on a bad coverage result.
  [[ "$(yq '.jobs.sonarcloud.if' "$WF")" == *'!cancelled()'* ]]
  local script="${BATS_TEST_TMPDIR}/needs.sh"
  yq -e ".jobs.sonarcloud.steps[] | select((.if // \"\") | test(\"needs\\.coverage\\.result != 'success'\")) | .run" \
    "$WF" > "$script"
  run env -i PATH="$PATH" COVERAGE_RESULT=failure bash -e "$script"
  [ "$status" -ne 0 ]
}

@test "both scan steps are conditioned on the gate's present output (#1390)" {
  local n
  n="$(yq "[.jobs.sonarcloud.steps[]
            | select((.uses // \"\") | test(\"^SonarSource/sonarqube-scan-action@\"))
            | select((.if // \"\") | test(\"steps\\.token\\.outputs\\.present == 'true'\"))]
           | length" "$WF")"
  [ "$n" = "2" ] || { echo "expected scan + retry gated on steps.token.outputs.present, found $n"; return 1; }
}

@test "gate: token present -> analysis runs" {
  run_gate "tok" "" "merge_group" ""
  [ "$status" -eq 0 ]
  grep -qx 'present=true' "$GATE_OUT"
}

@test "gate: fork pull request without the token FAILS the required check (#1390)" {
  run_gate "" "" "pull_request" "someone/.github"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error"* ]]
}

@test "gate: same-repo run without the token passes with a warning" {
  run_gate "" "" "merge_group" ""
  [ "$status" -eq 0 ]
  grep -qx 'present=false' "$GATE_OUT"
  [[ "$output" == *"::warning"* ]]
}

@test "gate: matches the standards template's gate (keep the two in sync)" {
  local tmpl="${REPO_ROOT}/standards/workflows/sonarcloud.yml"
  diff <(yq '.jobs.sonarcloud.steps[] | select(.id == "token") | .run' "$WF") \
       <(yq '.jobs.sonarcloud.steps[] | select(.id == "token") | .run' "$tmpl")
}
