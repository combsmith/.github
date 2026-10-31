#!/usr/bin/env bats
# End-to-end runs of scripts/coderabbit-audit.sh against stubbed gh and curl.
# These pin the outcomes that matter: no finding detail reaches public output,
# unverified findings never get dev-lead, routing, and fail-closed lifecycle.
# Every finding here is synthetic.

bats_require_minimum_version 1.5.0

ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
SCRIPT="$ROOT/scripts/coderabbit-audit.sh"
CANARY="CANARYSECRET"

fp() { printf "$1%.0s" {1..64}; }

# args: <fp char> <repo id> <path> <severity> <state>
finding() {
  jq -n --arg fp "$(fp "$1")" --arg repo "$2" --arg path "$3" --arg sev "$4" --arg state "$5" \
        --arg c "$CANARY" '{
    guid: "00000000-0000-0000-0000-000000000000",
    ruleId: ($c + "-rule"),
    level: "warning",
    message: {text: ($c + " exploit chain")},
    locations: [{physicalLocation: {artifactLocation: {uri: $path}, region: {startLine: 4242}}}],
    properties: {
      findingFingerprint: $fp,
      findingId: "11111111-2222-3333-4444-555555555555",
      severity: $sev, state: $state, source: "LLM",
      cwe: ($c + "-cwe"), category: ($c + "-category"), subsystemName: ($c + "-subsystem"),
      reachabilityCallStack: [($c + "-frame")],
      scanProvenance: {scope: {primary: {repositoryId: $repo, revision: "abc123"}}}
    }}'
}

sarif_of() { jq -s '{version: "2.1.0", runs: [{tool: {driver: {name: "CodeRabbit"}}, results: .}]}'; }

setup() {
  STUB_DIR="$(mktemp -d)"
  REPORT_DIR="$(mktemp -d)"
  STUB_LOG="$STUB_DIR/calls.log"
  export STUB_DIR REPORT_DIR STUB_LOG
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export CODERABBIT_API_KEY="test-key-value" ORG="combsmith"
  : > "$STUB_LOG"
  mkdir -p "$STUB_DIR/workflows" "$STUB_DIR/issues"

  cat > "$STUB_DIR/repos.ndjson" <<'JSON'
{"id":"101","name":"alpha","archived":false}
{"id":"102","name":"bravo","archived":false}
{"id":"103","name":".github","archived":false}
{"id":"104","name":"old","archived":true}
JSON
  printf 'jobs:\n  ci:\n    uses: combsmith/.github/.github/workflows/ci-reusable.yml@v1\n' \
    > "$STUB_DIR/workflows/stub.yml"
  printf 'jobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n' \
    > "$STUB_DIR/workflows/local.yml"

  {
    finding a 101 "src/$CANARY-path.ts" medium open        # new issue in alpha
    finding b 101 src/low.ts low open                      # filed by default
    finding c 102 .github/workflows/stub.yml high open     # routed to .github
    finding d 102 .github/workflows/local.yml high open    # stays in bravo
    finding e 101 src/gone.ts medium dismissed             # closes #5
    finding f 101 src/done.ts medium fixed                 # no issue: nothing to do
    finding 7 101 src/kept.ts high open                    # updates #7
    finding 9 999 src/foreign.ts high open                 # not an org repo
    finding 0 104 src/archived.ts high open                # archived repo
  } | sarif_of > "$STUB_DIR/export.sarif"

  # fingerprint 8 is open in GitHub but absent from the export.
  jq -n --arg e "$(fp e)" --arg g "$(fp 7)" --arg h "$(fp 8)" '[
    {number: 5, body: ("x <!-- coderabbit-audit:key=" + $e + " -->")},
    {number: 7, body: ("x <!-- coderabbit-audit:key=" + $g + " -->")},
    {number: 9, body: ("x <!-- coderabbit-audit:key=" + $h + " -->")},
    {number: 11, body: "an issue with the label but no marker"}
  ]' > "$STUB_DIR/issues/alpha.json"
}

teardown() {
  rm -rf "$STUB_DIR" "$REPORT_DIR"
}

writes() { grep -E '^gh issue (create|edit|close)' "$STUB_LOG" || true; }

# ── public output ──────────────────────────────────────────────────────────
@test "no finding detail reaches logs, issue text or the report dir" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q "$CANARY" <<< "$output" || false
  ! grep -q "$CANARY" <<< "$stderr" || false
  ! grep -q "$CANARY" "$STUB_LOG" || false
  ! grep -rq "$CANARY" "$REPORT_DIR" || false
  ! grep -q "4242" "$STUB_LOG" || false
}
@test "routing paths stay out of logs and issue text" {
  run --separate-stderr bash "$SCRIPT"
  ! grep -q "stub.yml" <<< "$stderr" || false
  ! grep -E '^gh issue' "$STUB_LOG" | grep -q "stub.yml" || false
  ! grep -rq "stub.yml" "$REPORT_DIR" || false
}
@test "the workflow uploads only the summary and pins its cron to the offset" {
  wf="$ROOT/.github/workflows/coderabbit-audit.yml"
  [ "$(grep -c 'path: \${{ runner.temp }}/coderabbit-report/summary.md' "$wf")" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]+path:' "$wf")" -eq 1 ]
  source "$ROOT/scripts/lib/cron-timing.sh"
  grep -q "cron: '$(cron_offset_minute coderabbit-audit.yml) 17 " "$wf"
}
@test "the API key travels on stdin, never in argv or logs" {
  run --separate-stderr bash "$SCRIPT"
  ! grep -q "test-key-value" "$STUB_LOG" || false
  ! grep -q "test-key-value" <<< "$stderr" || false
  grep -q 'x-coderabbitai-api-key: test-key-value' "$STUB_DIR/curl-stdin"
}
@test "the export is requested as SARIF with every state" {
  run bash "$SCRIPT"
  grep -E '^curl ' "$STUB_LOG" | grep -q 'format=sarif'
  grep -E '^curl ' "$STUB_LOG" | grep -q 'state=all'
}

# ── verification gate ──────────────────────────────────────────────────────
@test "no write ever adds dev-lead" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  writes | grep -q 'issue create'
  ! grep -E '^gh issue (create|edit)' "$STUB_LOG" | grep -qE -- '--(add-)?label [^ ]*dev-lead' || false
}
@test "new issues carry needs-verification, security and the priority" {
  run bash "$SCRIPT"
  grep -E "^gh issue create .*$(fp a | cut -c1-12)" "$STUB_LOG" \
    | grep -qE -- '--label coderabbit-audit.{1,2}needs-verification.{1,2}security.{1,2}priority:major '
}
@test "an update does not restore needs-verification after a person removed it" {
  run bash "$SCRIPT"
  grep -E '^gh issue edit 7 ' "$STUB_LOG" | grep -q -- '--add-label priority:critical'
  ! grep -E '^gh issue edit 7 ' "$STUB_LOG" | grep -qE -- '--add-label [^ ]*needs-verification' || false
}

# ── routing ────────────────────────────────────────────────────────────────
@test "a finding in a caller stub is filed in the repo that owns the workflow" {
  run bash "$SCRIPT"
  line=$(grep -E "^gh issue create .*$(fp c | cut -c1-12)" "$STUB_LOG")
  grep -q -- '--repo combsmith/.github ' <<< "$line"
  grep -q 'combsmith/bravo' <<< "$line"
}
@test "a finding in a workflow with its own steps stays in the scanned repo" {
  run bash "$SCRIPT"
  grep -E "^gh issue create .*$(fp d | cut -c1-12)" "$STUB_LOG" | grep -q -- '--repo combsmith/bravo '
}
@test "routing reads the workflow at the scanned revision" {
  run bash "$SCRIPT"
  grep -qF 'stub.yml\?ref=abc123' "$STUB_LOG"
}
@test "an existing issue stays where it is when the route changes" {
  jq -n --arg c "$(fp c)" '[{number: 3, body: ("<!-- coderabbit-audit:key=" + $c + " -->")}]' \
    > "$STUB_DIR/issues/bravo.json"
  run bash "$SCRIPT"
  grep -E '^gh issue edit 3 ' "$STUB_LOG" | grep -q -- '--repo combsmith/bravo '
  ! grep -E "^gh issue create .*$(fp c | cut -c1-12)" "$STUB_LOG" || false
}

# ── lifecycle ──────────────────────────────────────────────────────────────
@test "a dismissed finding closes its issue" {
  run bash "$SCRIPT"
  grep -E '^gh issue close 5 ' "$STUB_LOG" | grep -q 'dismissed'
}
@test "a finding absent from the export never closes its issue, and is counted" {
  run bash "$SCRIPT"
  ! grep -qE '^gh issue close 9 ' "$STUB_LOG" || false
  grep -q 'Left open (finding absent from this export) | 1 |' "$REPORT_DIR/summary.md"
}
@test "an issue without a marker is left alone" {
  run bash "$SCRIPT"
  ! grep -qE '^gh issue (close|edit) 11 ' "$STUB_LOG" || false
}
@test "a finding that already has an issue is updated, not filed again" {
  run bash "$SCRIPT"
  grep -qE '^gh issue edit 7 ' "$STUB_LOG"
  ! grep -E "^gh issue create .*$(fp 7 | cut -c1-12)" "$STUB_LOG" || false
}
@test "a fixed finding with no issue writes nothing" {
  run bash "$SCRIPT"
  ! grep -E '^gh issue' "$STUB_LOG" | grep -q "$(fp f | cut -c1-12)" || false
}
@test "every severity is filed by default" {
  run bash "$SCRIPT"
  grep -qE "^gh issue create .*$(fp b | cut -c1-12)" "$STUB_LOG"
  grep -q 'Not filed (below minimum severity) | 0 |' "$REPORT_DIR/summary.md"
}
@test "MIN_SEVERITY=medium counts low findings instead of filing them" {
  MIN_SEVERITY=medium run bash "$SCRIPT"
  ! grep -E "^gh issue create .*$(fp b | cut -c1-12)" "$STUB_LOG" || false
  grep -q 'Not filed (below minimum severity) | 1 |' "$REPORT_DIR/summary.md"
}
@test "findings in archived or foreign repos are skipped and counted" {
  run bash "$SCRIPT"
  ! grep -E "^gh issue create " "$STUB_LOG" | grep -qE "$(fp 9 | cut -c1-12)|$(fp 0 | cut -c1-12)" || false
  grep -q 'Skipped (repo archived or outside this org) | 2 |' "$REPORT_DIR/summary.md"
}
@test "a second run with the first run's issues writes no new issues" {
  jq -n --arg a "$(fp a)" --arg b "$(fp b)" --arg g "$(fp 7)" '[
    {number: 1, body: ("<!-- coderabbit-audit:key=" + $a + " -->")},
    {number: 4, body: ("<!-- coderabbit-audit:key=" + $b + " -->")},
    {number: 7, body: ("<!-- coderabbit-audit:key=" + $g + " -->")}]' > "$STUB_DIR/issues/alpha.json"
  jq -n --arg c "$(fp c)" '[{number: 2, body: ("<!-- coderabbit-audit:key=" + $c + " -->")}]' > "$STUB_DIR/issues/.github.json"
  jq -n --arg d "$(fp d)" '[{number: 3, body: ("<!-- coderabbit-audit:key=" + $d + " -->")}]' > "$STUB_DIR/issues/bravo.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qE '^gh issue create' "$STUB_LOG" || false
}

# ── fail closed ────────────────────────────────────────────────────────────
assert_no_writes_and_red() {
  [ "$status" -ne 0 ]
  [ -z "$(writes)" ]
  grep -q 'Issues were left untouched' "$REPORT_DIR/summary.md"
}

@test "a missing API key fails and writes nothing" {
  unset CODERABBIT_API_KEY
  run bash "$SCRIPT"
  assert_no_writes_and_red
  ! grep -q '^curl' "$STUB_LOG" || false
}
@test "an API error fails, writes nothing, and logs no response body" {
  echo "$CANARY error body" > "$STUB_DIR/error.body"
  STUB_HTTP_STATUS=403 STUB_SARIF="$STUB_DIR/error.body" run --separate-stderr bash "$SCRIPT"
  assert_no_writes_and_red
  grep -q 'HTTP 403' <<< "$stderr"
  ! grep -q "$CANARY" <<< "$stderr" || false
}
@test "a network failure fails and writes nothing" {
  STUB_CURL_FAIL=1 run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "a body that is not SARIF fails and writes nothing" {
  echo '{"data":[]}' > "$STUB_DIR/not-sarif"
  STUB_SARIF="$STUB_DIR/not-sarif" run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "a result with no fingerprint fails and writes nothing" {
  { finding a 101 src/a.ts medium open | jq 'del(.properties.findingFingerprint)'; } | sarif_of > "$STUB_DIR/bad"
  STUB_SARIF="$STUB_DIR/bad" run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "an unknown state fails and writes nothing" {
  finding a 101 src/a.ts medium triaged | sarif_of > "$STUB_DIR/bad"
  STUB_SARIF="$STUB_DIR/bad" run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "a result with no scanned repo fails and writes nothing" {
  { finding a 101 src/a.ts medium open | jq 'del(.properties.scanProvenance)'; } | sarif_of > "$STUB_DIR/bad"
  STUB_SARIF="$STUB_DIR/bad" run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "an unreadable workflow fails and writes nothing rather than guess a route" {
  STUB_FAIL_CONTENTS=1 run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "an unlistable repo fails and writes nothing rather than risk duplicates" {
  STUB_FAIL_ISSUE_LIST=1 run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "an unreadable repo list fails and writes nothing" {
  STUB_FAIL_REPOS=1 run bash "$SCRIPT"
  assert_no_writes_and_red
}
@test "a failed issue create turns the run red but still writes the summary" {
  STUB_FAIL_ISSUE_CREATE=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ -f "$REPORT_DIR/summary.md" ]
}
@test "an empty export closes nothing" {
  sarif_of < /dev/null > "$STUB_DIR/empty"
  STUB_SARIF="$STUB_DIR/empty" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(writes)" ]
}

# ── dispatch inputs ────────────────────────────────────────────────────────
@test "dry run reads everything and writes nothing" {
  DRY_RUN=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(writes)" ]
  ! grep -q '^gh label' "$STUB_LOG" || false
  grep -q 'Dry run: no issues written' "$REPORT_DIR/summary.md"
}
@test "TARGET_REPO narrows the export to that repo's id" {
  TARGET_REPO=combsmith/bravo run bash "$SCRIPT"
  grep -E '^curl ' "$STUB_LOG" | grep -q 'repo_id=102'
  grep -q 'absent from this export) | 0 |' "$REPORT_DIR/summary.md"
}
@test "an unknown TARGET_REPO fails and writes nothing" {
  TARGET_REPO=nope run bash "$SCRIPT"
  assert_no_writes_and_red
}
