#!/usr/bin/env bats
# Tests for reconcile-backlog.sh — the periodic/manual backlog reconcile
# (combsmith/.github#518). Runs the script with a tailored `gh` stub and
# DRY_RUN=1, and asserts it scans a repo's open issues/PRs + Ideas discussions
# and reconciles qualifying ones via the shared event-path helpers (logging the
# intended adds rather than mutating).

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  # Tailored gh stub: returns one qualifying issue, one Ideas discussion, and
  # "not found" for the draft-dedup lookup so reconcile takes the add path.
  local bin="${TT_TMP}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"repos/"*"/issues"*)
    # node_id <TAB> html_url <TAB> labels-objects-json  (one qualifying issue)
    printf 'I_node1\thttps://example.invalid/issues/1\t[{"name":"dev-lead"}]\n' ;;
  *graphql*discussions*)
    # number <TAB> title <TAB> url  (one Ideas discussion)
    printf '55\tShiny idea\thttps://example.invalid/discussions/55\n' ;;
  *graphql*)
    # find_project_item lookups (draft-dedup / remove path) → not found
    printf '' ;;
  *) printf '' ;;
esac
STUB
  chmod +x "$bin/gh"; PATH="${bin}:${PATH}"; export PATH
  export PROJECT_ID="PVT_test" PROJECT_URL="https://example.invalid/p/1" GH_TOKEN="t"
  export RECON_REPOS="combsmith/demo"   # skip installation lookup
  export DRY_RUN="1"
}
teardown() { tt_cleanup_tmpdir; }

run_recon() { run bash "${TT_SCRIPTS_DIR}/reconcile-backlog.sh"; }

@test "dry-run reconciles a qualifying issue (logs intended add, no mutation)" {
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[dry-run\] would add content I_node1 to project'
}

@test "dry-run reconciles an Ideas discussion as a draft" {
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[dry-run\] would add draft: \[Discussion #55\] Shiny idea'
}

@test "reports the repo count it scanned" {
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Reconciling 1 repo(s)'
  echo "$output" | grep -q 'Reconcile complete'
}

@test "an excluded label disqualifies an issue (no add)" {
  # override the stub to return a dev-lead + compliance-audit issue
  cat > "${TT_TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repos/"*"/issues"*) printf 'I_excl\thttps://example.invalid/issues/2\t[{"name":"dev-lead"},{"name":"compliance-audit"}]\n' ;;
  *graphql*discussions*) printf '' ;;
  *graphql*) printf '' ;;
esac
STUB
  chmod +x "${TT_TMP}/bin/gh"
  run_recon
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would add content I_excl'
}
