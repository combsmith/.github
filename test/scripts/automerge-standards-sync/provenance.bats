#!/usr/bin/env bats
# Provenance gate for scripts/automerge-standards-sync.sh (combsmith/.github#1386).
#
# Label + branch name + PR author say nothing about what is on the branch NOW: a
# repository writer can push to a `standards-sync/` branch after the deployer
# opens the PR. The approver identity's code-owner approval must therefore only
# be granted when the CURRENT head is still a pure standards deploy:
#
#   (a) every commit is authored/committed by the deployer (the PR author),
#   (b) every push to the head branch was made by the deployer,
#   (c) every changed path is a stub the standards deploy is allowed to write,
#
# and the approval + auto-merge are bound to the verified head SHA.
#
# Unit tests exercise the pure decision functions in
# scripts/lib/standards-sync-provenance.sh; integration tests drive the script
# against a fake `gh` and assert no approval / auto-merge happens on rejection.

load 'helpers/gh-stub'

HEAD_SHA="headsha0000000000000000000000000000000001"

setup() {
  TT_TMP="$(mktemp -d)"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/automerge-standards-sync.sh"
  LIB="${REPO_ROOT}/scripts/lib/standards-sync-provenance.sh"
  DEPLOY_SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  install_gh_stub
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/workflows-20261027 don-petry standards-sync)"
  export GH_PR_VIEW_JSON
}

teardown() { rm -rf "$TT_TMP"; }

# pr_json <author> <headRefName> <last-commit-author> <labels-csv>
pr_json() {
  local labels_json
  labels_json="$(printf '%s\n' "$4" | tr ',' '\n' | jq -R '{name: .}' | jq -sc '.')"
  jq -nc --arg author "$1" --arg head "$2" --arg last "$3" --arg sha "$HEAD_SHA" \
    --argjson labels "$labels_json" '
    { number: 42, url: "https://github.com/combsmith/acme/pull/42",
      author: {login: $author}, headRefName: $head, headRefOid: $sha,
      labels: $labels, commits: [ {authors: [ {login: $last} ]} ] }'
}

run_single() {
  run env GH_TOKEN=x APPROVER_TOKEN=faketoken bash "$SCRIPT" \
    --repo combsmith/acme --pr 42 "$@"
}

assert_no_approval_no_merge() {
  refute_call 'pulls/42/reviews'
  refute_call 'pr review'
  refute_call 'pr merge'
  refute_call '--admin'
}

# ── Allowed paths are derived from the deploy script's DEPLOYABLE_WORKFLOWS ───

@test "allowed paths are .github/workflows/<w> for every DEPLOYABLE_WORKFLOWS entry" {
  source "$LIB"
  run ssp_allowed_paths "$DEPLOY_SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF '.github/workflows/dev-lead.yml'
  echo "$output" | grep -qxF '.github/workflows/feature-ideation.yml'
  # Tech-stack workflows are never deployed, so never in scope.
  refute_output_has '.github/workflows/ci.yml'
  refute_output_has '.github/workflows/sonarcloud.yml'
  # Exactly one path per deployable workflow — no drift from the deploy script.
  local expected
  expected=$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${DEPLOYABLE_WORKFLOWS[@]}"' _ "$DEPLOY_SCRIPT" | grep -c .)
  [ "$(echo "$output" | grep -c .)" -eq "$expected" ]
}

@test "allowed paths fail closed when the deploy script cannot be loaded" {
  source "$LIB"
  run ssp_allowed_paths "${TT_TMP}/does-not-exist.sh"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  printf 'exit 1\n' > "${TT_TMP}/broken.sh"
  run ssp_allowed_paths "${TT_TMP}/broken.sh"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ── (a) commit identity ───────────────────────────────────────────────────────

@test "commits: all by the deployer and ending at head → accepted" {
  source "$LIB"
  local c; c=$(printf '%s\n%s\n' "$(commit_ndjson aaa don-petry don-petry)" "$(commit_ndjson "$HEAD_SHA" don-petry don-petry)" | jq -sc .)
  run ssp_check_commits "$c" don-petry "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "commits: an Update-branch merge (committer web-flow, verified) by the deployer → accepted" {
  source "$LIB"
  local c; c=$(printf '%s\n%s\n' "$(commit_ndjson aaa don-petry don-petry)" "$(commit_ndjson "$HEAD_SHA" don-petry web-flow true)" | jq -sc .)
  run ssp_check_commits "$c" don-petry "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "commits: an unverified commit claiming committer web-flow → rejected" {
  source "$LIB"
  local c; c=$(commit_ndjson "$HEAD_SHA" don-petry web-flow false | jq -sc .)
  run ssp_check_commits "$c" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'committer'
}

@test "commits: a commit authored by another writer → rejected" {
  source "$LIB"
  local c; c=$(printf '%s\n%s\n' "$(commit_ndjson aaa don-petry don-petry)" "$(commit_ndjson "$HEAD_SHA" mallory mallory)" | jq -sc .)
  run ssp_check_commits "$c" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'mallory'
}

@test "commits: a commit with no linked GitHub author → rejected" {
  source "$LIB"
  local c; c=$(jq -nc --arg h "$HEAD_SHA" '[{sha: $h, author: null, committer: {login: "don-petry"}}]')
  run ssp_check_commits "$c" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
}

@test "commits: list not ending at the verified head → rejected" {
  source "$LIB"
  local c; c=$(commit_ndjson othersha don-petry don-petry | jq -sc .)
  run ssp_check_commits "$c" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'head'
}

@test "commits: empty, malformed, or at the 250-commit API cap → rejected" {
  source "$LIB"
  run ssp_check_commits '[]' don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  run ssp_check_commits 'not json' don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  local many
  many=$(jq -nc --arg h "$HEAD_SHA" '[range(250) | {sha: $h, author: {login: "don-petry"}, committer: {login: "don-petry"}}]')
  run ssp_check_commits "$many" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
}

# ── (b) push identity ─────────────────────────────────────────────────────────

@test "pushes: every ref update by the deployer, newest at head → accepted" {
  source "$LIB"
  local p; p=$(printf '%s\n%s\n' \
    "$(push_ndjson don-petry "$HEAD_SHA" 2026-10-27T00:00:02Z)" \
    "$(push_ndjson don-petry base 2026-10-27T00:00:01Z branch_creation)" | jq -sc .)
  run ssp_check_pushes "$p" don-petry "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "pushes: a push by another writer (even with deployer-attributed commits) → rejected" {
  source "$LIB"
  local p; p=$(printf '%s\n%s\n' \
    "$(push_ndjson mallory "$HEAD_SHA" 2026-10-27T00:00:02Z)" \
    "$(push_ndjson don-petry base 2026-10-27T00:00:01Z branch_creation)" | jq -sc .)
  run ssp_check_pushes "$p" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'mallory'
}

@test "pushes: newest recorded push is not the verified head → rejected" {
  source "$LIB"
  local p; p=$(push_ndjson don-petry older 2026-10-27T00:00:02Z | jq -sc .)
  run ssp_check_pushes "$p" don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
  run ssp_check_pushes '[]' don-petry "$HEAD_SHA"
  [ "$status" -ne 0 ]
}

# ── (c) changed paths ─────────────────────────────────────────────────────────

@test "files: only deployable stubs added/modified → accepted" {
  source "$LIB"
  local f; f=$(printf '%s\n%s\n' "$(file_ndjson .github/workflows/dev-lead.yml)" "$(file_ndjson .github/workflows/pr-review.yml added)" | jq -sc .)
  run ssp_check_files "$f" "$(printf '%s\n' .github/workflows/dev-lead.yml .github/workflows/pr-review.yml)"
  [ "$status" -eq 0 ]
}

@test "files: a path outside the deploy scope → rejected" {
  source "$LIB"
  local f; f=$(printf '%s\n%s\n' "$(file_ndjson .github/workflows/dev-lead.yml)" "$(file_ndjson src/app.js)" | jq -sc .)
  run ssp_check_files "$f" .github/workflows/dev-lead.yml
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'src/app.js'
}

@test "files: a removed or renamed stub → rejected (the deploy only writes)" {
  source "$LIB"
  run ssp_check_files "$(file_ndjson .github/workflows/dev-lead.yml removed | jq -sc .)" .github/workflows/dev-lead.yml
  [ "$status" -ne 0 ]
  run ssp_check_files "$(file_ndjson .github/workflows/dev-lead.yml renamed | jq -sc .)" .github/workflows/dev-lead.yml
  [ "$status" -ne 0 ]
}

@test "files: empty diff, malformed list, or empty allowlist → rejected" {
  source "$LIB"
  run ssp_check_files '[]' .github/workflows/dev-lead.yml
  [ "$status" -ne 0 ]
  run ssp_check_files 'nope' .github/workflows/dev-lead.yml
  [ "$status" -ne 0 ]
  run ssp_check_files "$(file_ndjson .github/workflows/dev-lead.yml | jq -sc .)" ''
  [ "$status" -ne 0 ]
}

# ── Integration: the script never approves an unverified head ─────────────────

@test "script: a foreign commit on the sync branch → no approval, no auto-merge" {
  GH_COMMITS_NDJSON="$(printf '%s\n%s\n' "$(commit_ndjson aaa don-petry don-petry)" "$(commit_ndjson "$HEAD_SHA" mallory mallory)")"
  export GH_COMMITS_NDJSON
  run_single
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'provenance'
  echo "$output" | grep -q 'mallory'
  assert_no_approval_no_merge
}

@test "script: a push by another writer → no approval, no auto-merge" {
  GH_ACTIVITY_NDJSON="$(push_ndjson mallory "$HEAD_SHA" 2026-10-27T00:00:02Z)"
  export GH_ACTIVITY_NDJSON
  run_single
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'provenance'
  assert_no_approval_no_merge
}

@test "script: a change outside the standards-deploy scope → no approval, no auto-merge" {
  GH_FILES_NDJSON="$(printf '%s\n%s\n' "$(file_ndjson .github/workflows/dev-lead.yml)" "$(file_ndjson scripts/deploy.sh)")"
  export GH_FILES_NDJSON
  run_single
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'scripts/deploy.sh'
  assert_no_approval_no_merge
}

@test "script: a non-deployable workflow (ci.yml) is out of scope" {
  GH_FILES_NDJSON="$(file_ndjson .github/workflows/ci.yml)"
  export GH_FILES_NDJSON
  run_single
  [ "$status" -eq 0 ]
  assert_no_approval_no_merge
}

@test "script: an unreadable commit / file / push list fails closed" {
  GH_COMMITS_RC=1; export GH_COMMITS_RC
  run_single
  [ "$status" -eq 0 ]
  assert_no_approval_no_merge
  unset GH_COMMITS_RC; : > "$GH_CALLS"
  GH_FILES_RC=1; export GH_FILES_RC
  run_single
  assert_no_approval_no_merge
  unset GH_FILES_RC; : > "$GH_CALLS"
  GH_ACTIVITY_RC=1; export GH_ACTIVITY_RC
  run_single
  assert_no_approval_no_merge
}

@test "script: commit and file lists are read with pagination" {
  run_single
  [ "$status" -eq 0 ]
  grep -qE 'gh api --paginate repos/combsmith/acme/pulls/42/commits' "$GH_CALLS"
  grep -qE 'gh api --paginate repos/combsmith/acme/pulls/42/files' "$GH_CALLS"
  grep -qE 'gh api --paginate repos/combsmith/acme/activity' "$GH_CALLS"
}

@test "script: dry-run also refuses an unverified head" {
  GH_COMMITS_NDJSON="$(commit_ndjson "$HEAD_SHA" mallory mallory)"
  export GH_COMMITS_NDJSON
  run_single --dry-run
  [ "$status" -eq 0 ]
  refute_output_has 'would approve'
  assert_no_approval_no_merge
}

# ── Binding to the verified head SHA ──────────────────────────────────────────

@test "script: the approval is bound to the verified head SHA (commit_id)" {
  run_single
  [ "$status" -eq 0 ]
  grep -q "pulls/42/reviews .*commit_id=${HEAD_SHA}" "$GH_CALLS"
  grep -q 'event=APPROVE' "$GH_CALLS"
  grep -qE "pr merge 42 --repo combsmith/acme --auto --squash --match-head-commit ${HEAD_SHA}" "$GH_CALLS"
  refute_call '--admin'
}

@test "script: head moved after verification → auto-merge NOT enabled" {
  GH_HEAD_SHA_AFTER="movedsha00000000000000000000000000000002"; export GH_HEAD_SHA_AFTER
  run_single
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'movedsha'
  grep -q "commit_id=${HEAD_SHA}" "$GH_CALLS"
  refute_call 'pr merge'
  refute_call '--admin'
}

@test "script: a PR view without a head SHA fails closed" {
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/workflows-20261027 don-petry standards-sync | jq -c 'del(.headRefOid)')"
  export GH_PR_VIEW_JSON
  run_single
  [ "$status" -eq 0 ]
  assert_no_approval_no_merge
}
