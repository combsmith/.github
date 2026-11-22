#!/usr/bin/env bats
# The dismiss-stale-bot-reviews stub INLINES its two scripts as quoted heredocs so
# one file is self-sufficient (no checkout, no tag). The scripts under scripts/ are
# the tested source; these tests fail if a heredoc drifts from its script, if the
# template and the .github/workflows copy differ, or if the stub fetches `ref: v1`.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
TEMPLATE="${REPO_ROOT}/standards/workflows/dismiss-stale-bot-reviews.yml"
LOCAL_COPY="${REPO_ROOT}/.github/workflows/dismiss-stale-bot-reviews.yml"

# extract_heredoc <stub> <delimiter> — print the heredoc body, YAML indent (10) removed.
extract_heredoc() {
  awk -v d="$2" '
    $0 ~ ("<<\x27" d "\x27$") { on = 1; next }
    on && $0 ~ ("^[[:space:]]*" d "$") { exit }
    on { print }
  ' "$1" | sed 's/^ \{10\}//'
}

@test "orchestrator heredoc is byte-identical to scripts/dismiss-stale-bot-reviews.sh" {
  for stub in "$TEMPLATE" "$LOCAL_COPY"; do
    run diff <(extract_heredoc "$stub" DSBR_ORCHESTRATOR_EOF) "${REPO_ROOT}/scripts/dismiss-stale-bot-reviews.sh"
    [ "$status" -eq 0 ] || { echo "$stub: $output"; false; }
  done
}

@test "core heredoc is byte-identical to scripts/lib/dismiss-stale-bot-reviews.sh" {
  for stub in "$TEMPLATE" "$LOCAL_COPY"; do
    run diff <(extract_heredoc "$stub" DSBR_CORE_EOF) "${REPO_ROOT}/scripts/lib/dismiss-stale-bot-reviews.sh"
    [ "$status" -eq 0 ] || { echo "$stub: $output"; false; }
  done
}

@test "template and .github/workflows copy are identical" {
  run cmp "$TEMPLATE" "$LOCAL_COPY"
  [ "$status" -eq 0 ]
}

@test "neither copy pins ref: v1 or checks out tooling" {
  for stub in "$TEMPLATE" "$LOCAL_COPY"; do
    run grep -nE 'ref:[[:space:]]*v1|actions/checkout|continue-on-error' "$stub"
    [ "$status" -eq 1 ]
  done
}

@test "run block carries no expression and a missing script is an error" {
  run python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
run = d["jobs"]["dismiss"]["steps"][0]["run"]
assert "${{" not in run, "run block contains an expression"
assert "::error::inlined script missing" in run
' "$TEMPLATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "stub triggers: PR events, schedule, workflow_dispatch with dry_run" {
  run python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); on = d.get("on", d.get(True))
assert on["pull_request"]["types"] == ["synchronize"]
assert on["pull_request_review"]["types"] == ["submitted"]
assert on["schedule"][0]["cron"] == "23 */4 * * *"
assert on["workflow_dispatch"]["inputs"]["dry_run"]["type"] == "boolean"
j = d["jobs"]["dismiss"]["if"]
assert "dependabot[bot]" in j and "head.repo.full_name" in j
' "$TEMPLATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "neither stub reads github.event.repository (undefined for schedule events)" {
  for stub in "$TEMPLATE" "$LOCAL_COPY"; do
    run grep -nE 'github\.event\.repository|DSBR_OWNER|DSBR_NAME' "$stub"
    [ "$status" -eq 1 ]
  done
}
