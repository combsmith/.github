#!/usr/bin/env bats
# Guard: a failed SonarCloud quality gate fails the required `SonarCloud` check.
#
# The `code-quality` ruleset requires the `SonarCloud` context, which is the
# Actions job in sonarcloud.yml. That job only reflects the gate when the scan
# passes -Dsonar.qualitygate.wait=true; without it the job succeeds as soon as
# the analysis uploads. The scan's first attempt is continue-on-error (for CDN
# blips on the scanner download), so the wiring around it decides whether a gate
# failure actually fails the job:
#   - the retry runs only when no analysis was uploaded (no report-task.txt),
#   - a final step fails the job when the first attempt failed and the retry
#     was skipped.
# Checked in this repo's workflow and in the template other repos copy.
# Standard: standards/ci-standards.md#3-sonarcloud-analysis-sonarcloudyml

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
FILES=(
  "${REPO_ROOT}/.github/workflows/sonarcloud.yml"
  "${REPO_ROOT}/standards/workflows/sonarcloud.yml"
)

# Print the `if:` value of the step named $2 in file $1 (single-line `if:` only).
step_if() {
  awk -v want="$2" '
    /^      - name: / { name = substr($0, index($0, ": ") + 2); next }
    /^      - /       { name = "" }
    name == want && /^        if: / { sub(/^        if: /, ""); print; exit }
  ' "$1"
}

# Print the body of the step named $2 in file $1, up to the next step,
# without comment lines (the comment above the next step would leak in).
step_body() {
  awk -v want="$2" '
    /^      - / { on = 0 }
    /^      - name: / { on = (substr($0, index($0, ": ") + 2) == want) }
    on && !/^[[:space:]]*#/
  ' "$1"
}

# The file without comment lines: the template header names the flag in prose.
code_lines() {
  grep -v '^[[:space:]]*#' "$1"
}

@test "scan and retry both wait for the quality gate" {
  local f n
  for f in "${FILES[@]}"; do
    n="$(code_lines "$f" | grep -c -- '-Dsonar.qualitygate.wait=true')"
    [ "$n" -eq 2 ] || { echo "${f}: expected qualitygate.wait on scan and retry, found ${n}"; return 1; }
  done
}

@test "the gate wait is limited to pull_request events" {
  # A main-branch gate verdict must not fail push runs or stall the merge queue.
  local f
  for f in "${FILES[@]}"; do
    awk '
      /-Dsonar\.qualitygate\.wait=true/ {
        if ($0 !~ /github\.event_name == .pull_request./ && prev !~ /github\.event_name == .pull_request./) bad = 1
      }
      { prev = $0 }
      END { exit bad }
    ' <(code_lines "$f") || { echo "${f}: qualitygate.wait is not conditioned on pull_request"; return 1; }
  done
}

@test "the first scan attempt stays continue-on-error with id sonar" {
  local f body
  for f in "${FILES[@]}"; do
    body="$(step_body "$f" "SonarCloud Scan")"
    grep -Fq 'id: sonar' <<< "$body" || { echo "${f}: first scan has no id: sonar"; return 1; }
    grep -Fq 'continue-on-error: true' <<< "$body" || { echo "${f}: first scan is not continue-on-error"; return 1; }
  done
}

@test "the retry is skipped once an analysis was uploaded" {
  local f cond
  for f in "${FILES[@]}"; do
    cond="$(step_if "$f" "SonarCloud Scan (retry)")"
    [ -n "$cond" ] || { echo "${f}: retry step has no if:"; return 1; }
    grep -Fq "steps.sonar.outcome == 'failure'" <<< "$cond" || { echo "${f}: retry not keyed on the first attempt failing: ${cond}"; return 1; }
    grep -Fq "hashFiles('.scannerwork/report-task.txt') == ''" <<< "$cond" || { echo "${f}: retry would re-run a gate failure: ${cond}"; return 1; }
    step_body "$f" "SonarCloud Scan (retry)" | grep -Fq 'id: sonar_retry' || { echo "${f}: retry has no id: sonar_retry"; return 1; }
    # The retry must not swallow its own failure.
    ! step_body "$f" "SonarCloud Scan (retry)" | grep -Fq 'continue-on-error' || { echo "${f}: retry is continue-on-error"; return 1; }
  done
}

@test "a gate failure that skipped the retry fails the job" {
  local f cond
  for f in "${FILES[@]}"; do
    cond="$(step_if "$f" "Fail on SonarCloud quality gate")"
    [ -n "$cond" ] || { echo "${f}: no 'Fail on SonarCloud quality gate' step"; return 1; }
    grep -Fq "steps.sonar.outcome == 'failure'" <<< "$cond" || { echo "${f}: fail step not keyed on the first attempt: ${cond}"; return 1; }
    grep -Fq "steps.sonar_retry.outcome == 'skipped'" <<< "$cond" || { echo "${f}: fail step not keyed on the skipped retry: ${cond}"; return 1; }
    step_body "$f" "Fail on SonarCloud quality gate" | grep -Eq '^[[:space:]]+exit 1[[:space:]]*$' || { echo "${f}: fail step does not exit 1"; return 1; }
  done
}

@test "step helpers find nothing for a missing step" {
  # Negative control, so the checks above cannot pass vacuously.
  [ -z "$(step_if "${FILES[0]}" "No such step")" ]
  [ -z "$(step_body "${FILES[0]}" "No such step")" ]
  [ -n "$(step_body "${FILES[0]}" "SonarCloud Scan")" ]
}
