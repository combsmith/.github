#!/usr/bin/env bats
# Tests for scripts/lib/standards-deploy.sh — sd_deploy_via_pr()
#
# The function shells out to `gh` for every GitHub interaction, so each test
# installs a fake `gh` on PATH that logs its invocations to $GH_CALLS and whose
# behaviour is driven by GH_* env vars. Assertions check both the returned
# outcome token and the sequence of gh calls (e.g. that an idempotent skip makes
# no mutating calls, that a failed branch-create still falls back to reuse).

load 'helpers/setup'

# ---------------------------------------------------------------------------
# Fake gh installed on PATH
# ---------------------------------------------------------------------------
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
sub="${1:-}"; shift || true
args="$*"
case "$sub" in
  pr)
    case "${1:-}" in
      list)   printf '%s' "${GH_EXISTING_PR:-}" ;;
      create)
        [ "${GH_PR_CREATE_RC:-0}" -ne 0 ] && exit "${GH_PR_CREATE_RC}"
        printf '%s\n' "${GH_PR_URL:-https://github.com/o/r/pull/1}" ;;
    esac
    ;;
  api)
    endpoint="${1:-}"
    case "$endpoint" in
      */git/refs)          exit "${GH_REF_CREATE_RC:-0}" ;;
      */git/ref/heads/*)
        if printf '%s' "$args" | grep -q 'object.sha'; then
          printf '%s' "${GH_BASE_SHA-basesha111}"
        else
          exit "${GH_REF_EXISTS_RC:-0}"
        fi ;;
      *contents*"?"ref=*)  printf '%s' "${GH_FILE_SHA:-}" ;;
      *contents*)          exit "${GH_PUT_RC:-0}" ;;
      repos/*)             printf '%s' "${GH_DEFAULT_BRANCH:-main}" ;;
    esac
    ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"
  export PATH
}

setup() {
  tt_make_tmpdir
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"

  # A real local file to deploy.
  LOCAL_FILE="${TT_TMP}/add-to-project.yml"
  printf 'name: stub\non: [issues]\n' > "$LOCAL_FILE"

  install_gh_stub
  # shellcheck source=/dev/null
  source "${TT_SCRIPTS_LIB_DIR}/standards-deploy.sh"
}

teardown() { tt_cleanup_tmpdir; }

# Convenience wrapper with stable args.
deploy() {
  sd_deploy_via_pr "combsmith/markets" ".github/workflows/add-to-project.yml" \
    "$LOCAL_FILE" "standards-sync/add-to-project" "standards-sync" \
    "chore: sync add-to-project.yml" "PR body here"
}

# ---------------------------------------------------------------------------
# Happy path: no existing PR, fresh file → branch, PUT, PR opened
# ---------------------------------------------------------------------------
@test "opens a PR and reports OPENED with the url" {
  run deploy
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED https://github.com/o/r/pull/1" ]
}

@test "happy path makes the full create call sequence" {
  run deploy
  [ "$status" -eq 0 ]
  grep -q 'gh pr list --repo combsmith/markets --label standards-sync' "$GH_CALLS"
  grep -q 'gh api repos/combsmith/markets/git/refs --method POST' "$GH_CALLS"
  grep -q 'gh api repos/combsmith/markets/contents/.github/workflows/add-to-project.yml --method PUT' "$GH_CALLS"
  grep -q 'gh pr create --repo combsmith/markets --head standards-sync/add-to-project --base main' "$GH_CALLS"
  grep -q -- '--label standards-sync' "$GH_CALLS"
}

# The multi-file primitive: two stubs deploy as a single PR (two PUTs, one
# pr create) — the per-repo batching used by the fleet re-sync.
@test "deploys multiple files in a single PR" {
  local f2="${TT_TMP}/dependency-audit.yml"
  printf 'name: stub2\non: [push]\n' > "$f2"
  run sd_deploy_files_via_pr "combsmith/markets" "standards-sync/workflows" \
    "standards-sync" "chore: sync 2 stubs" "body" \
    ".github/workflows/add-to-project.yml" "$LOCAL_FILE" \
    ".github/workflows/dependency-audit.yml" "$f2"
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED https://github.com/o/r/pull/1" ]
  grep -q 'contents/.github/workflows/add-to-project.yml --method PUT' "$GH_CALLS"
  grep -q 'contents/.github/workflows/dependency-audit.yml --method PUT' "$GH_CALLS"
  # exactly one PR opened for the batch
  [ "$(grep -c 'gh pr create' "$GH_CALLS")" -eq 1 ]
}

@test "rejects an odd number of file arguments" {
  run sd_deploy_files_via_pr "combsmith/markets" "b" "l" "t" "body" \
    ".github/workflows/only-a-path.yml"
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED bad-file-args" ]
}

# Regression: consumer repos don't carry the standards-sync label, and
# `gh pr create --label` fails outright if it's absent — so the lib must ensure
# the label exists, before the PR is created. (combsmith/.github#480.)
@test "ensures the label exists before opening the PR" {
  run deploy
  [ "$status" -eq 0 ]
  grep -q 'gh label create standards-sync --repo combsmith/markets' "$GH_CALLS"
  local label_line prc_line
  label_line=$(grep -n 'gh label create' "$GH_CALLS" | head -1 | cut -d: -f1)
  prc_line=$(grep -n 'gh pr create' "$GH_CALLS" | head -1 | cut -d: -f1)
  [ "$label_line" -lt "$prc_line" ]
}

# ---------------------------------------------------------------------------
# Idempotency: an open PR already exists → skip, no mutations
# ---------------------------------------------------------------------------
@test "skips when an open PR already exists on the branch" {
  GH_EXISTING_PR="42"; export GH_EXISTING_PR
  run deploy
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP_PR_OPEN 42" ]
}

@test "idempotent skip makes no branch/PUT/PR-create calls" {
  GH_EXISTING_PR="42"; export GH_EXISTING_PR
  run deploy
  [ "$status" -eq 0 ]
  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'contents/.* --method PUT' "$GH_CALLS"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Branch reuse: create returns non-zero but the ref already exists
# ---------------------------------------------------------------------------
@test "reuses an existing branch and still opens the PR" {
  GH_REF_CREATE_RC="1"; export GH_REF_CREATE_RC   # POST refs fails (already exists)
  GH_REF_EXISTS_RC="0"; export GH_REF_EXISTS_RC    # ref lookup succeeds
  run deploy
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED https://github.com/o/r/pull/1" ]
  grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Update path: file already present on the branch → PUT carries its blob SHA
# ---------------------------------------------------------------------------
@test "passes the existing blob sha when updating a drifted stub" {
  GH_FILE_SHA="deadbeefsha"; export GH_FILE_SHA
  run deploy
  [ "$status" -eq 0 ]
  grep -q 'contents/.github/workflows/add-to-project.yml --method PUT.*--raw-field sha=deadbeefsha' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Failure modes
# ---------------------------------------------------------------------------
@test "fails cleanly when the base sha cannot be resolved" {
  GH_BASE_SHA=""; export GH_BASE_SHA
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED no-base-sha" ]
}

@test "fails when the branch can neither be created nor found" {
  GH_REF_CREATE_RC="1"; export GH_REF_CREATE_RC
  GH_REF_EXISTS_RC="1"; export GH_REF_EXISTS_RC
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED no-branch" ]
}

@test "fails when the PUT is rejected" {
  GH_PUT_RC="1"; export GH_PUT_RC
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED put-failed" ]
}

@test "fails when the PR cannot be created" {
  GH_PR_CREATE_RC="1"; export GH_PR_CREATE_RC
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED pr-create-failed" ]
}

@test "fails when the local file is missing" {
  run sd_deploy_via_pr "combsmith/markets" ".github/workflows/x.yml" \
    "${TT_TMP}/does-not-exist.yml" "standards-sync/x" "standards-sync" "t" "b"
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED missing-local-file" ]
}
