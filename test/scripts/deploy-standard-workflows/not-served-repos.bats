#!/usr/bin/env bats
# NOT_SERVED_REPOS — repos the standard-workflow sweep never touches.
#
# Distinct from SKIP_REPOS: a SKIP_REPO is inside the standard and self-manages
# it; a not-served repo is outside the standard by the Maintainer's decision. The
# sweep must skip it whether it is reached by the org-wide listing or named with
# --repo, must make no gh call for it, and must not drag it into the SKIP_REPOS
# reconciliation guard.

bats_require_minimum_version 1.5.0

setup() {
  TT_TMP="$(mktemp -d)"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  mkdir -p "${TT_TMP}/bin"
  cat > "${TT_TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
exit 1
STUB
  chmod +x "${TT_TMP}/bin/gh"
}

teardown() { rm -rf "$TT_TMP"; }

@test "is_not_served_repo: software-factory and its canary are not served" {
  run bash -c 'source "$1" >/dev/null 2>&1; is_not_served_repo software-factory && is_not_served_repo software-factory-canary' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "is_not_served_repo: matching is case-insensitive" {
  run bash -c 'source "$1" >/dev/null 2>&1; is_not_served_repo Software-Factory && is_not_served_repo SOFTWARE-FACTORY-CANARY' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "is_not_served_repo: an ordinary repo, and the SKIP_REPOS, are served" {
  run bash -c 'source "$1" >/dev/null 2>&1; is_not_served_repo markets || is_not_served_repo .github || is_not_served_repo .github-private' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "NOT_SERVED_REPOS and SKIP_REPOS share no repo" {
  run bash -c 'source "$1" >/dev/null 2>&1; for r in "${NOT_SERVED_REPOS[@]}"; do is_skipped_repo "$r" && { echo "$r"; exit 1; }; done; exit 0' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--repo naming a not-served repo is skipped, and no gh call is made for it" {
  PATH="${TT_TMP}/bin:$PATH" run bash "$SCRIPT" --repo software-factory --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  software-factory (not served"* ]]
  [ ! -s "$GH_CALLS" ]
}

@test "the sweep still deploys to a served repo named beside a not-served one" {
  run bash -c '
    source "$1" >/dev/null 2>&1
    deploy_repo() { echo "DEPLOYED $1"; }
    parse_args() { :; }
    TARGET_REPO=""; TARGET_WORKFLOW="add-to-project.yml"; DRY_RUN=true
    gh() { printf "%s\n" markets software-factory software-factory-canary broodly; }
    main
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPLOYED markets"* ]]
  [[ "$output" == *"DEPLOYED broodly"* ]]
  [[ "$output" != *"DEPLOYED software-factory"* ]]
}
