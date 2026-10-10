#!/usr/bin/env bats
# Tests for the "does being behind actually block this PR?" gate (issue #1272).
#
# The reusable used to update-branch EVERY behind PR on every push to the base,
# even where the base's rules do not require branches to be up to date — each
# no-op merge commit restarted every review/CI cycle on every open PR. It now
# updates a behind PR only when the base branch's effective rules (rulesets +
# classic protection, read through the API) require branches to be up to date
# (strict checks). Merge-queue / auto-merge state is NOT a condition.
#
# A conflicting PR is still attempted so the existing conflict notice fires,
# and an unreadable gate fails safe to the old behaviour (update).
#
# Two layers are tested:
#   - the pure decision function in lib/update-gate.sh (unit tests);
#   - the reusable's real "Update behind non-Dependabot PRs" run-block, end to
#     end against a fixture-driven `gh` stub that applies `--jq` with real jq,
#     so the decision is proven to come from the fixture configuration.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/auto-rebase-reusable.yml"

# setup — initialize test environment with temporary directories and gh stub
setup() {
  tt_make_tmpdir

  TT_WORK="${TT_TMP}/work"
  mkdir -p "$TT_WORK"
  ln -s "$TT_REPO_ROOT" "${TT_WORK}/.auto-rebase-tooling"

  FIX_DIR="${TT_TMP}/fixtures"
  mkdir -p "$FIX_DIR"
  export FIX_DIR

  TT_BIN="${TT_TMP}/bin"
  mkdir -p "$TT_BIN"
  _install_gh_stub
  PATH="${TT_BIN}:${PATH}"
  export PATH

  RUN_SCRIPT="${TT_TMP}/run.sh"
  yq -r '.jobs.auto-rebase.steps[]
           | select(.name == "Update behind non-Dependabot PRs")
           | .run' "$REUSABLE" > "$RUN_SCRIPT"

  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/update-gate.sh"
  . "${TT_SCRIPTS_DIR}/lib/gate-facts.sh"
}

# teardown — clean up temporary directories after test
teardown() {
  tt_cleanup_tmpdir
}

# ── fixture-driven gh stub ───────────────────────────────────────────────────
#
# `gh api ENDPOINT` serves "${FIX_DIR}/<key>.json" where <key> is ENDPOINT with
# every non-alphanumeric byte replaced by `_`; GraphQL calls are keyed by the
# PR number (`graphql_<n>`). A "<key>.rc" file makes the call fail with that
# exit code (body still printed to stdout, `gh: <message>` to stderr — as the
# real gh does). A missing fixture is a 404. `--jq` is applied with real jq.

# _install_gh_stub — install fixture-driven gh command stub in test binary directory
_install_gh_stub() {
  cat > "${TT_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${FIX_DIR}/gh-calls.log"

_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

_serve() {
  local key="$1" jq_expr="$2" body rc=0
  if [ -f "${FIX_DIR}/${key}.json" ]; then
    body="$(cat "${FIX_DIR}/${key}.json")"
    [ -f "${FIX_DIR}/${key}.rc" ] && rc="$(cat "${FIX_DIR}/${key}.rc")"
  else
    body='{"message":"Not Found","status":"404"}'
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$body"
    printf 'gh: %s (HTTP %s)\n' \
      "$(printf '%s' "$body" | jq -r '.message // "error"')" \
      "$(printf '%s' "$body" | jq -r '.status // "500"')" >&2
    exit "$rc"
  fi
  if [ -n "$jq_expr" ]; then
    printf '%s' "$body" | jq -r "$jq_expr"
  else
    printf '%s\n' "$body"
  fi
}

if [ "$1" = "api" ]; then
  shift
  endpoint="" jq_expr="" number="" paginate=false slurp=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jq) jq_expr="$2"; shift 2 ;;
      -X|-H) shift 2 ;;
      --paginate) paginate=true; shift ;;
      --slurp) slurp=true; shift ;;
      -f|-F)
        case "$2" in number=*) number="${2#number=}" ;; esac
        printf '%s\n' "$2" >> "${FIX_DIR}/gh-fields.log"
        shift 2 ;;
      *) endpoint="$1"; shift ;;
    esac
  done

  # Serve the response, wrapping in a page array if both --paginate and --slurp are used
  _serve_paginated() {
    local key="$1" jq_expr="$2" paginate="$3" slurp="$4" body rc=0
    if [ -f "${FIX_DIR}/${key}.json" ]; then
      body="$(cat "${FIX_DIR}/${key}.json")"
      [ -f "${FIX_DIR}/${key}.rc" ] && rc="$(cat "${FIX_DIR}/${key}.rc")"
    else
      body='{"message":"Not Found","status":"404"}'
      rc=1
    fi
    if [ "$rc" -eq 0 ] && [ "$paginate" = "true" ] && [ "$slurp" = "true" ]; then
      body="[$body]"
    fi
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$body"
      printf 'gh: %s (HTTP %s)\n' \
        "$(printf '%s' "$body" | jq -r '.message // "error"')" \
        "$(printf '%s' "$body" | jq -r '.status // "500"')" >&2
      exit "$rc"
    fi
    if [ -n "$jq_expr" ]; then
      printf '%s' "$body" | jq -r "$jq_expr"
    else
      printf '%s\n' "$body"
    fi
  }

  case "$endpoint" in
    graphql) _serve "graphql_${number}" "$jq_expr" ;;
    */update-branch) _serve "$(_key "$endpoint")" "$jq_expr" ;;
    *) _serve_paginated "$(_key "$endpoint")" "$jq_expr" "$paginate" "$slurp" ;;
  esac
  exit $?
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  # gh pr view N --repo R --json comments --jq EXPR
  pr="$3" jq_expr=""
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac
  done
  printf '{"comments":[]}' | jq -r "$jq_expr"
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  printf '%s\n' "$*" >> "${FIX_DIR}/comments-posted.log"
  exit 0
fi

exit 0
STUB
  chmod +x "${TT_BIN}/gh"
}

_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# _fixture ENDPOINT BODY [RC]
_fixture() {
  local key
  key="$(_key "$1")"
  printf '%s\n' "$2" > "${FIX_DIR}/${key}.json"
  rm -f "${FIX_DIR}/${key}.rc"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "${FIX_DIR}/${key}.rc"; fi
}

# One open same-repo PR #7 (head `feature`) on `main`, 3 commits behind.
_seed_behind_pr() {
  _fixture "repos/owner/repo/pulls?state=open&per_page=100" '[
    {"number":7,"user":{"login":"alice"},"head":{"ref":"feature","repo":{"full_name":"owner/repo"}},"base":{"ref":"main","repo":{"full_name":"owner/repo"}}}
  ]'
  _fixture "repos/owner/repo/pulls/7" '{"number":7,"base":{"ref":"main"}}'
  _fixture "repos/owner/repo/compare/main...feature" '{"behind_by":3}'
  _fixture "repos/owner/repo/pulls/7/update-branch" '{"message":"Updating pull request branch."}'
  _fixture "repos/owner/repo/git/ref/heads/main" '{"object":{"sha":"basesha123"}}'
  # No classic branch protection by default.
  _fixture "repos/owner/repo/branches/main/protection/required_status_checks" \
    '{"message":"Branch not protected","status":"404"}' 1
  _pr_state false false MERGEABLE
}

# _rules STRICT — a ruleset with a required_status_checks rule.
_rules() {
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" "[
    {\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":$1,\"required_status_checks\":[{\"context\":\"ci\"}]}},
    {\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":1}}
  ]"
}

# _pr_state IN_QUEUE AUTO_MERGE_WITH_QUEUE MERGEABLE [LABEL...]
_pr_state() {
  local in_queue="$1" queued_auto="$2" mergeable="$3" labels="" l
  shift 3
  for l in "$@"; do labels+="${labels:+,}{\"name\":\"$l\"}"; done
  local auto=null
  [ "$queued_auto" = true ] && auto='{"enabledAt":"2026-01-01T00:00:00Z"}'
  printf '{"data":{"repository":{"pullRequest":{"isInMergeQueue":%s,"isMergeQueueEnabled":%s,"autoMergeRequest":%s,"mergeable":"%s","labels":{"nodes":[%s]}}}}}\n' \
    "$in_queue" "$queued_auto" "$auto" "$mergeable" "$labels" > "${FIX_DIR}/graphql_7.json"
}

# _updated — check if update-branch was called for PR #7
_updated() { grep -q 'pulls/7/update-branch' "${FIX_DIR}/gh-calls.log"; }

# _run_workflow — execute the auto-rebase update script with test environment
_run_workflow() {
  run env \
    FIX_DIR="$FIX_DIR" \
    GH_TOKEN="stub-token" \
    HAS_PAT="${HAS_PAT:-true}" \
    REPO="owner/repo" \
    ELIGIBILITY="all" \
    AUTO_REBASE_MERGEABLE_POLL_SECONDS=0 \
    bash --noprofile --norc -eo pipefail -c \
      "cd '${TT_WORK}' && exec bash --noprofile --norc -eo pipefail '${RUN_SCRIPT}'"
}

# ── AC1: each condition, end to end through the reusable run-block ───────────

@test "gate: strict required and PR behind → updates, logging the strict condition" {
  _seed_behind_pr
  _rules true
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"PR #7 (feature) is 3 commit(s) behind main — updating branch [gate: base branch rules require branches to be up to date]"* ]]
  [[ "$output" == *"Branch updated"* ]]
}

@test "gate: strict not required → does NOT update, logs that none applied" {
  _seed_behind_pr
  _rules false
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"PR #7 (feature) is 3 commit(s) behind main — skipping update [gate: none applied"* ]]
  [[ "$output" != *"Branch updated"* ]]
}

@test "gate: no ruleset and no classic protection at all → does NOT update" {
  _seed_behind_pr
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" '[]'
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"skipping update [gate: none applied"* ]]
}

@test "gate: classic branch protection with strict checks → updates" {
  _seed_behind_pr
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" '[]'
  _fixture "repos/owner/repo/branches/main/protection/required_status_checks" \
    '{"strict":true,"contexts":["ci"]}'
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"updating branch [gate: base branch rules require branches to be up to date]"* ]]
}

@test "gate: PR in a merge queue with strict off → does NOT update" {
  _seed_behind_pr
  _rules false
  _pr_state true false MERGEABLE
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"skipping update [gate: none applied"* ]]
}

@test "gate: auto-merge enabled on a queue-enabled base with strict off → does NOT update" {
  _seed_behind_pr
  _rules false
  _pr_state false true MERGEABLE
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"skipping update [gate: none applied"* ]]
}

@test "gate: queued and auto-merge PRs ARE updated when strict is required" {
  _seed_behind_pr
  _rules true
  _pr_state true false MERGEABLE
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  rm -f "${FIX_DIR}/gh-calls.log"
  _pr_state false true MERGEABLE
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"updating branch [gate: base branch rules require branches to be up to date]"* ]]
}

@test "gate: ready label alone does not trigger update" {
  _seed_behind_pr
  _rules false
  _pr_state false false MERGEABLE bug auto-rebase:ready
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"PR #7 (feature) is 3 commit(s) behind main — skipping update [gate: none applied"* ]]
}

@test "gate: fork PR is skipped as today (never gated, never updated)" {
  _seed_behind_pr
  _rules true
  _fixture "repos/owner/repo/pulls?state=open&per_page=100" '[
    {"number":7,"user":{"login":"mallory"},"head":{"ref":"feature","repo":{"full_name":"mallory/repo"}},"base":{"ref":"main","repo":{"full_name":"owner/repo"}}}
  ]'
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"No open non-Dependabot same-repo PRs"* ]]
}

@test "gate: rules unreadable (API error) → updates as today with a 'could not evaluate' log line" {
  _seed_behind_pr
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" \
    '{"message":"Resource not accessible by integration","status":"403"}' 1
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"PR #7 (feature) is 3 commit(s) behind main — updating branch [gate: could not evaluate"* ]]
  [[ "$output" == *"updating as before"* ]]
}

@test "gate: classic protection unreadable (403) → updates with a 'could not evaluate' log line" {
  _seed_behind_pr
  _rules false
  _fixture "repos/owner/repo/branches/main/protection/required_status_checks" \
    '{"message":"Resource not accessible by integration","status":"403"}' 1
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"updating branch [gate: could not evaluate"* ]]
}

@test "gate: PR mergeability unreadable → updates with a 'could not evaluate' log line" {
  _seed_behind_pr
  _rules false
  rm -f "${FIX_DIR}/graphql_7.json"
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"updating branch [gate: could not evaluate"* ]]
}

@test "gate: an up-to-date PR is still skipped before the gate is consulted" {
  _seed_behind_pr
  _rules true
  _fixture "repos/owner/repo/compare/main...feature" '{"behind_by":0}'
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi
  [[ "$output" == *"PR #7 (feature) is up to date — skipping"* ]]
  if grep -q 'rules/branches' "${FIX_DIR}/gh-calls.log"; then false; fi
}

# ── AC2: the decision is derived from configuration ──────────────────────────

@test "gate: flipping only the fixture ruleset's strict flag flips the outcome" {
  _seed_behind_pr

  _rules false
  _run_workflow
  [ "$status" -eq 0 ]
  if _updated; then false; fi

  _rules true
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
}

# ── AC3: conflict handling is unaffected ────────────────────────────────────

@test "gate: a conflicting PR (strict off) is still attempted and receives the conflict notice" {
  _seed_behind_pr
  _rules false
  _pr_state false false CONFLICTING
  _fixture "repos/owner/repo/pulls/7/update-branch" \
    '{"message":"merge conflict between base and head","status":"422"}' 1
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"updating branch [gate: merge conflict"* ]]
  grep -qF '<!-- auto-rebase-conflict:basesha123 -->' "${FIX_DIR}/comments-posted.log"
  grep -qF 'Auto-rebase failed — merge conflict' "${FIX_DIR}/comments-posted.log"
}

@test "gate: a conflicting PR under strict rules still receives the conflict notice" {
  _seed_behind_pr
  _rules true
  _fixture "repos/owner/repo/pulls/7/update-branch" \
    '{"message":"merge conflict between base and head","status":"422"}' 1
  _run_workflow
  [ "$status" -eq 0 ]
  grep -qF '<!-- auto-rebase-conflict:basesha123 -->' "${FIX_DIR}/comments-posted.log"
}

@test "gate: mergeability still UNKNOWN after polling → updates as before (fail safe)" {
  _seed_behind_pr
  _rules false
  _pr_state false false UNKNOWN
  _run_workflow
  [ "$status" -eq 0 ]
  _updated
  [[ "$output" == *"updating branch [gate: could not evaluate"* ]]
  [ "$(grep -c '^api graphql' "${FIX_DIR}/gh-calls.log")" -gt 1 ]
}

# ── AC4: exactly one gate log line per behind PR ─────────────────────────────

@test "gate: exactly one per-PR gate line is logged for each behind PR" {
  _seed_behind_pr
  _rules false
  _fixture "repos/owner/repo/pulls?state=open&per_page=100" '[
    {"number":7,"user":{"login":"alice"},"head":{"ref":"feature","repo":{"full_name":"owner/repo"}},"base":{"ref":"main","repo":{"full_name":"owner/repo"}}},
    {"number":8,"user":{"login":"bob"},"head":{"ref":"other","repo":{"full_name":"owner/repo"}},"base":{"ref":"main","repo":{"full_name":"owner/repo"}}}
  ]'
  _fixture "repos/owner/repo/pulls/8" '{"number":8,"base":{"ref":"main"}}'
  _fixture "repos/owner/repo/compare/main...other" '{"behind_by":1}'
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"isMergeQueueEnabled":false,"autoMergeRequest":null,"mergeable":"MERGEABLE","labels":{"nodes":[{"name":"auto-rebase:ready"}]}}}}}' \
    > "${FIX_DIR}/graphql_8.json"
  _run_workflow
  [ "$status" -eq 0 ]
  [ "$(grep -c '^PR #7 .*\[gate: ' <<< "$output")" -eq 1 ]
  [ "$(grep -c '^PR #8 .*\[gate: ' <<< "$output")" -eq 1 ]
  [[ "$output" == *"PR #7 (feature) is 3 commit(s) behind main — skipping update [gate: none applied"* ]]
  [[ "$output" == *"PR #8 (other) is 1 commit(s) behind main — skipping update [gate: none applied"* ]]
}

# ── unit: pure decision function ─────────────────────────────────────────────

@test "decide: strict true → update" {
  run auto_rebase_gate_decide true MERGEABLE
  [ "$status" -eq 0 ]
  [[ "$output" == *"require branches to be up to date"* ]]
}

@test "decide: nothing applies and mergeable → skip" {
  run auto_rebase_gate_decide false MERGEABLE
  [ "$status" -eq 1 ]
  [[ "$output" == "none applied"* ]]
}

@test "decide: strict unknown → update with could-not-evaluate (never skip on unreadable config)" {
  run auto_rebase_gate_decide unknown MERGEABLE
  [ "$status" -eq 0 ]
  [[ "$output" == "could not evaluate"* ]]
}

@test "decide: conflicting → update attempt (conflict notice path)" {
  run auto_rebase_gate_decide false CONFLICTING
  [ "$status" -eq 0 ]
  [[ "$output" == "merge conflict"* ]]
}

@test "decide: mergeability UNKNOWN with nothing else applying → pending (3)" {
  run auto_rebase_gate_decide false UNKNOWN
  [ "$status" -eq 3 ]
}

@test "strict_policy: an unreadable ruleset response is 'unknown', never 'false'" {
  # Classic protection answers "not protected", so the ONLY way to reach 'unknown'
  # here is the unreadable ruleset. Mapping it to 'false' instead would fall
  # through to the classic answer and print 'false', failing this test.
  _fixture "repos/owner/repo/branches/main/protection/required_status_checks" \
    '{"message":"Branch not protected","status":"404"}' 1
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" 'not json'
  run auto_rebase_strict_policy owner/repo main
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  # A failed ruleset call (API error) is unreadable too.
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" \
    '{"message":"Server Error","status":"500"}' 1
  run auto_rebase_strict_policy owner/repo main
  [ "$output" = "unknown" ]
  # Control: a READABLE empty rule list with the same classic answer is 'false',
  # which proves the two cases above are decided by the ruleset result.
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" '[]'
  run auto_rebase_strict_policy owner/repo main
  [ "$output" = "false" ]
}

@test "strict_policy: strict flag with an empty required_status_checks list is not strict" {
  _fixture "repos/owner/repo/rules/branches/main?per_page=100" \
    '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[]}}]'
  _fixture "repos/owner/repo/branches/main/protection/required_status_checks" \
    '{"message":"Branch not protected","status":"404"}' 1
  run auto_rebase_strict_policy owner/repo main
  [ "$status" -eq 0 ]
  [ "$output" != "true" ]
}
