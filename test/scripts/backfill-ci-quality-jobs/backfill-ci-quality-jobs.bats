#!/usr/bin/env bats
# Unit tests for scripts/backfill-ci-quality-jobs.sh — the fleet backfill of the
# secret-scan + coverage CI jobs and the --verify gate for requiring them in
# code-quality (combsmith/.github#581).

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
BACKFILL="$REPO_DIR/scripts/backfill-ci-quality-jobs.sh"
TEMPLATE_CI="$REPO_DIR/standards/workflows/ci.yml"

setup() {
  WORK="$(mktemp -d)"
  STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"; export PATH="$STUB_BIN:$PATH"
  GH_LOG="$WORK/gh.log"; export GH_LOG
  export FIXTURES="$WORK/fx"; mkdir -p "$FIXTURES"
  # shellcheck source=/dev/null
  source "$BACKFILL"
  set +u +o pipefail   # the script sets -u/pipefail; keep -e, which bats relies on to fail a test
}
teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }

# A typical repo ci.yml: one stack job and no quality jobs.
write_repo_ci() {
  cat > "$1" <<'YAML'
name: CI
on:
  pull_request:
    branches: [main]
permissions: {}
jobs:
  build-and-test:
    name: build-and-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: |
          npm ci
          npm test
YAML
}

# --- cbf_job_status ----------------------------------------------------------

@test "job_status: missing when neither id nor check name exists" {
  write_repo_ci "$WORK/ci.yml"
  run cbf_job_status "$WORK/ci.yml" coverage coverage
  [ "$status" -eq 0 ]; [ "$output" = missing ]
}

@test "job_status: present by check name under a different job id" {
  write_repo_ci "$WORK/ci.yml"
  printf '  gitleaks:\n    name: Secret scan (gitleaks)\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' >> "$WORK/ci.yml"
  run cbf_job_status "$WORK/ci.yml" secret-scan "Secret scan (gitleaks)"
  [ "$output" = present ]
}

@test "job_status: a nameless job reports its id as the check name" {
  write_repo_ci "$WORK/ci.yml"
  printf '  coverage:\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' >> "$WORK/ci.yml"
  run cbf_job_status "$WORK/ci.yml" coverage coverage
  [ "$output" = present ]
}

@test "job_status: conflict when the id is taken by a job with another check name" {
  write_repo_ci "$WORK/ci.yml"
  printf '  coverage:\n    name: Coverage report\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' >> "$WORK/ci.yml"
  run cbf_job_status "$WORK/ci.yml" coverage coverage
  [ "$output" = conflict ]
}

# --- cbf_extract_job ---------------------------------------------------------

@test "extract_job: secret-scan block comes from the template unchanged, lead comment included" {
  run cbf_extract_job "$TEMPLATE_CI" secret-scan
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "  # Canonical secret-scan job"* ]]
  [[ "$output" == *"  secret-scan:"* ]]
  [[ "$output" == *"name: Secret scan (gitleaks)"* ]]
  [[ "$output" == *"gitleaks detect --source . --config .gitleaks.toml"* ]]
  # Stops before the next job and its lead comment.
  [[ "$output" != *"coverage:"* ]]
  [[ "$output" != *"Stack-aware coverage"* ]]
  # Every line appears in the template exactly as written.
  while IFS= read -r l; do grep -qxF -- "$l" "$TEMPLATE_CI" || [ -z "$l" ]; done <<< "$output"
}

@test "extract_job: coverage block (the last job) keeps its trailing per-stack comments" {
  run cbf_extract_job "$TEMPLATE_CI" coverage
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "  # Stack-aware coverage"* ]]
  [[ "$output" == *"    name: coverage"* ]]
  [[ "$output" == *"Rust:   cargo llvm-cov --workspace"* ]]
  [[ "$output" != *"secret-scan"* ]]
}

@test "extract_job: a top-level key after jobs: ends the last job's block" {
  printf 'jobs:\n  coverage:\n    name: coverage\n    runs-on: ubuntu-latest\nenv:\n  X: y\n' > "$WORK/tpl.yml"
  run cbf_extract_job "$WORK/tpl.yml" coverage
  [ "$status" -eq 0 ]
  [[ "$output" != *"env:"* ]]
  [[ "$output" != *"X: y"* ]]
}

@test "extract_job: unknown job id fails" {
  run cbf_extract_job "$TEMPLATE_CI" no-such-job
  [ "$status" -ne 0 ]
}

# --- cbf_backfill_file / cbf_inject_block ------------------------------------

@test "backfill_file: adds both jobs, keeps the original jobs, result is valid YAML" {
  write_repo_ci "$WORK/ci.yml"
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "secret-scan coverage" ]
  run yq -r '.jobs | keys | join(",")' "$WORK/out.yml"
  [ "$output" = "build-and-test,secret-scan,coverage" ]
  run yq -r '.jobs.coverage.name + "|" + .jobs."secret-scan".name' "$WORK/out.yml"
  [ "$output" = "coverage|Secret scan (gitleaks)" ]
  # The injected job bodies are identical to the template's.
  [ "$(yq -o=json '.jobs."secret-scan"' "$WORK/out.yml")" = "$(yq -o=json '.jobs."secret-scan"' "$TEMPLATE_CI")" ]
  [ "$(yq -o=json '.jobs.coverage' "$WORK/out.yml")" = "$(yq -o=json '.jobs.coverage' "$TEMPLATE_CI")" ]
  # The original file is an unchanged prefix of the output.
  head -n "$(wc -l < "$WORK/ci.yml")" "$WORK/out.yml" | diff - "$WORK/ci.yml"
}

@test "backfill_file: idempotent — running again adds nothing" {
  write_repo_ci "$WORK/ci.yml"
  cbf_backfill_file "$WORK/ci.yml" "$WORK/once.yml" >/dev/null
  run cbf_backfill_file "$WORK/once.yml" "$WORK/twice.yml"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  diff "$WORK/once.yml" "$WORK/twice.yml"
}

@test "backfill_file: adds only the missing job when one is already present" {
  write_repo_ci "$WORK/ci.yml"
  printf '  coverage:\n    name: coverage\n    runs-on: ubuntu-latest\n    steps: [{run: "npm run cov"}]\n' >> "$WORK/ci.yml"
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml"
  [ "$status" -eq 0 ]; [ "$output" = "secret-scan" ]
  [ "$(yq -r '.jobs.coverage.steps[0].run' "$WORK/out.yml")" = "npm run cov" ]
}

@test "backfill_file: re-indents to a repo with 4-space job keys" {
  cat > "$WORK/ci.yml" <<'YAML'
name: CI
on: [pull_request]
jobs:
    test:
        runs-on: ubuntu-latest
        steps:
            - run: make test
YAML
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml"
  [ "$status" -eq 0 ]
  grep -qx '    secret-scan:' "$WORK/out.yml"
  grep -qx '    coverage:' "$WORK/out.yml"
  [ "$(yq -r '.jobs | keys | join(",")' "$WORK/out.yml")" = "test,secret-scan,coverage" ]
  [ "$(yq -o=json '.jobs.coverage' "$WORK/out.yml")" = "$(yq -o=json '.jobs.coverage' "$TEMPLATE_CI")" ]
}

@test "backfill_file: inserts inside jobs: when a top-level key follows it" {
  cat > "$WORK/ci.yml" <<'YAML'
name: CI
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test

# trailing top-level key after jobs
env:
  FOO: bar
YAML
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.jobs | keys | join(",")' "$WORK/out.yml")" = "test,secret-scan,coverage" ]
  [ "$(yq -r '.env.FOO' "$WORK/out.yml")" = "bar" ]
  tail -n 3 "$WORK/out.yml" | grep -qx 'env:'
}

@test "backfill_file: does not add a check another workflow file already reports" {
  write_repo_ci "$WORK/ci.yml"
  printf 'on: [pull_request]\njobs:\n  coverage:\n    runs-on: ubuntu-latest\n    steps: [{run: "npm run cov"}]\n' > "$WORK/coverage.yml"
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml" "$WORK/coverage.yml"
  [ "$status" -eq 0 ]; [ "$output" = "secret-scan" ]
  [ "$(yq -r '.jobs | keys | join(",")' "$WORK/out.yml")" = "build-and-test,secret-scan" ]
}

@test "backfill_file: returns 2 and names the job on a conflict" {
  write_repo_ci "$WORK/ci.yml"
  printf '  coverage:\n    name: Coverage report\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' >> "$WORK/ci.yml"
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml"
  [ "$status" -eq 2 ]
  [[ "$output" == *coverage* ]]
}

@test "backfill_file: fails on a ci.yml with no jobs: mapping" {
  printf 'name: CI\non: [push]\n' > "$WORK/ci.yml"
  run cbf_backfill_file "$WORK/ci.yml" "$WORK/out.yml"
  [ "$status" -eq 1 ]
}

# --- deploy + verify against a stubbed gh ------------------------------------

# gh stub. Serves a file from $FIXTURES/<repo-name>/<path>, or HTTP 404 if it is
# absent. Serves check runs from $FIXTURES/<repo-name>/checks-<sha> (one name per
# line, optionally "name|conclusion"; default success), and a PR head sha from $FIXTURES/<repo-name>/pr-sha. Logs
# every call to $GH_LOG.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
case "$args" in
  "auth status"*) exit 0 ;;
  *"repo list"*) printf '%s' "${REPO_LIST:-[]}"; exit 0 ;;
esac
path=""; for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
repo="${path#repos/}"; repo="${repo#*/}"; repo="${repo%%/*}"
case "$args" in
  "pr list"*)
    r=""; prev=""; for a in "$@"; do [ "$prev" = --repo ] && r="${a#*/}"; prev="$a"; done
    cat "$FIXTURES/$r/pr-sha" 2>/dev/null || true; exit 0 ;;
  *"/contents/"*)
    f="$FIXTURES/$repo/${path#*/contents/}"
    [ -d "$f" ] && { ls -1 "$f"; exit 0; }   # directory listing → file names (the --jq result)
    [ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$f" ;;
  *"/check-runs"*)
    # Build the API's JSON from "name[|conclusion]" lines and apply the caller's
    # real --jq filter, so the passing-conclusion filter is under test.
    sha="${path#*/commits/}"; sha="${sha%%/*}"
    filter=""; prev=""; for a in "$@"; do [ "$prev" = --jq ] && filter="$a"; prev="$a"; done
    f="$FIXTURES/$repo/checks-$sha"; [ -f "$f" ] || f=/dev/null
    jq -R -s 'split("\n") | map(select(length > 0) | split("|") | {name: .[0], conclusion: (.[1] // "success")}) | {check_runs: .}' "$f" \
      | jq -r "$filter" ;;
  *"/commits/"*) echo "tipsha" ;;
  *) echo "main" ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

seed_repo() {  # seed_repo <name> [with-gitleaks]
  mkdir -p "$FIXTURES/$1/.github/workflows"
  write_repo_ci "$FIXTURES/$1/.github/workflows/ci.yml"
  [ "${2:-}" = with-gitleaks ] && echo 'title = "x"' > "$FIXTURES/$1/.gitleaks.toml"
  return 0
}

@test "backfill_repo: dry-run plans both jobs plus the .gitleaks.toml seed, opens nothing" {
  _stub_gh; seed_repo alpha
  DRY_RUN=true run cbf_backfill_repo combsmith/alpha
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN combsmith/alpha — add job(s): secret-scan coverage; seed .gitleaks.toml" ]
  ! grep -q -- '--method PUT\|pr create' "$GH_LOG"
}

@test "backfill_repo: no seed when .gitleaks.toml already exists" {
  _stub_gh; seed_repo beta with-gitleaks
  DRY_RUN=true run cbf_backfill_repo combsmith/beta
  [ "$output" = "PLAN combsmith/beta — add job(s): secret-scan coverage" ]
}

@test "backfill_repo: NO_CI when the repo has no ci.yml" {
  _stub_gh; mkdir -p "$FIXTURES/gamma"
  DRY_RUN=true run cbf_backfill_repo combsmith/gamma
  [ "$status" -eq 0 ]; [[ "$output" == "NO_CI combsmith/gamma"* ]]
}

@test "backfill_repo: OK when both jobs are already present" {
  _stub_gh; seed_repo delta
  cbf_backfill_file "$FIXTURES/delta/.github/workflows/ci.yml" "$WORK/full.yml" >/dev/null
  cp "$WORK/full.yml" "$FIXTURES/delta/.github/workflows/ci.yml"
  DRY_RUN=true run cbf_backfill_repo combsmith/delta
  [ "$status" -eq 0 ]; [[ "$output" == "OK combsmith/delta"* ]]
}

@test "backfill_repo: OK when another workflow file supplies the missing check" {
  _stub_gh; seed_repo lambda with-gitleaks
  cbf_backfill_file "$FIXTURES/lambda/.github/workflows/ci.yml" "$WORK/full.yml" >/dev/null
  yq -i 'del(.jobs.coverage)' "$WORK/full.yml"
  cp "$WORK/full.yml" "$FIXTURES/lambda/.github/workflows/ci.yml"
  printf 'on: [pull_request]\njobs:\n  coverage:\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' \
    > "$FIXTURES/lambda/.github/workflows/coverage.yml"
  DRY_RUN=true run cbf_backfill_repo combsmith/lambda
  [ "$status" -eq 0 ]; [[ "$output" == "OK combsmith/lambda"* ]]
}

@test "backfill_repo: real run opens ONE standards-sync PR carrying ci.yml + .gitleaks.toml" {
  _stub_gh; seed_repo eps
  sd_deploy_files_via_pr() {
    printf '%s\0' "$@" > "$WORK/deploy-args"
    cp "$7" "$WORK/deployed-ci.yml"
    echo "OPENED https://github.com/combsmith/eps/pull/1"
  }
  DRY_RUN=false run cbf_backfill_repo combsmith/eps
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED combsmith/eps https://github.com/combsmith/eps/pull/1" ]
  mapfile -d '' args < "$WORK/deploy-args"
  [ "${#args[@]}" -eq 9 ]   # repo branch label title body + 2 (path, file) pairs
  [[ "${args[4]}" == *"#581"* ]]
  [ "${args[0]}" = combsmith/eps ]
  [ "${args[1]}" = standards-sync/ci-quality-jobs ]
  [ "${args[2]}" = standards-sync ]
  [ "${args[5]}" = .github/workflows/ci.yml ]
  [ "${args[7]}" = .gitleaks.toml ]
  [ "${args[8]}" = "$REPO_DIR/standards/gitleaks.toml" ]
  [ "$(yq -r '.jobs | keys | join(",")' "$WORK/deployed-ci.yml")" = "build-and-test,secret-scan,coverage" ]
}

@test "verify_repo: PASS when the default-branch tip reports both checks" {
  _stub_gh; mkdir -p "$FIXTURES/zeta"
  printf 'build-and-test\nSecret scan (gitleaks)\ncoverage\n' > "$FIXTURES/zeta/checks-tipsha"
  run cbf_verify_repo combsmith/zeta
  [ "$status" -eq 0 ]; [ "$output" = "PASS combsmith/zeta" ]
}

@test "verify_repo: MISSING (non-zero) names the absent context" {
  _stub_gh; mkdir -p "$FIXTURES/eta"
  printf 'build-and-test\nSecret scan (gitleaks)\n' > "$FIXTURES/eta/checks-tipsha"
  run cbf_verify_repo combsmith/eta
  [ "$status" -ne 0 ]; [ "$output" = 'MISSING combsmith/eta "coverage"' ]
}

@test "verify_repo: a failed or still-running check does not count as reported" {
  _stub_gh; mkdir -p "$FIXTURES/iota"
  printf 'Secret scan (gitleaks)|failure\ncoverage|\n' > "$FIXTURES/iota/checks-tipsha"
  run cbf_verify_repo combsmith/iota
  [ "$status" -ne 0 ]
  [ "$output" = 'MISSING combsmith/iota "Secret scan (gitleaks)", "coverage"' ]
}

@test "verify_repo: a skipped check counts as passing (as it does for a required check)" {
  _stub_gh; mkdir -p "$FIXTURES/kappa"
  printf 'Secret scan (gitleaks)|skipped\ncoverage|neutral\n' > "$FIXTURES/kappa/checks-tipsha"
  run cbf_verify_repo combsmith/kappa
  [ "$status" -eq 0 ]
}

@test "verify_repo: falls back to the latest PR head when CI runs only on pull_request" {
  _stub_gh; mkdir -p "$FIXTURES/theta"
  echo prsha > "$FIXTURES/theta/pr-sha"
  printf 'Secret scan (gitleaks)\ncoverage\n' > "$FIXTURES/theta/checks-prsha"
  run cbf_verify_repo combsmith/theta
  [ "$status" -eq 0 ]; [ "$output" = "PASS combsmith/theta" ]
}

@test "main --verify --all: covers the apply-rulesets fleet and fails if any repo is missing a check" {
  _stub_gh
  export REPO_LIST='[{"name":"zeta","isArchived":false},{"name":"eta","isArchived":false},{"name":"old","isArchived":true},{"name":"software-factory","isArchived":false}]'
  mkdir -p "$FIXTURES/zeta" "$FIXTURES/eta"
  printf 'Secret scan (gitleaks)\ncoverage\n' > "$FIXTURES/zeta/checks-tipsha"
  printf 'Secret scan (gitleaks)\n' > "$FIXTURES/eta/checks-tipsha"
  run cbf_main --verify --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"PASS combsmith/zeta"* ]]
  [[ "$output" == *'MISSING combsmith/eta "coverage"'* ]]
  [[ "$output" == *"do NOT add them to code-quality.json"* ]]
  [[ "$output" != *old* ]]
  [[ "$output" != *software-factory* ]]
}

@test "main: rejects --repo together with --all, and no target" {
  _stub_gh
  run cbf_main --repo x --all
  [ "$status" -eq 2 ]
  run cbf_main
  [ "$status" -eq 2 ]
}

# --- the rollout order guard -------------------------------------------------

@test "code-quality.json does not require coverage/secret-scan until the backfill is verified (#581)" {
  # Step 3 of #581 is a deliberate, separate change made only after
  # `backfill-ci-quality-jobs.sh --verify --all` exits 0. When that happens,
  # remove this test in the same PR that adds the two contexts.
  run jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' \
    "$REPO_DIR/standards/rulesets/code-quality.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SonarCloud"* ]]   # proves the file was actually read
  [[ "$output" != *"coverage"* ]]
  [[ "$output" != *"Secret scan (gitleaks)"* ]]
}
