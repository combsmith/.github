#!/usr/bin/env bats
# Both retrigger sweeps skip repos in NOT_SERVED_REPOS (#1343): a stale finding
# in software-factory(-canary) must never receive a dev-lead trigger.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  : >"$GH_STUB_LOG"
  export GH_API_RETRY_BASE_DELAY=0
  GH_STUB_SEARCH_BODY='{"total_count":2,"items":[{"number":5,"repository_url":"https://api.github.com/repos/combsmith/software-factory-canary","created_at":"2020-01-01T00:00:00Z","title":"stale canary"},{"number":6,"repository_url":"https://api.github.com/repos/combsmith/software-factory","created_at":"2020-01-01T00:00:00Z","title":"stale sf"}]}'
  export GH_STUB_SEARCH_BODY
}

teardown() {
  tt_cleanup_tmpdir
}

@test "primary and legacy sweeps skip not-served repos and never trigger them" {
  GH_TOKEN=fake ORG=combsmith DRY_RUN=true \
    TRIGGER_LABEL=dev-lead LEGACY_TRIGGER_LABEL=claude \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping software-factory-canary#5"* ]]
  [[ "$output" == *"Skipping software-factory#6"* ]]
  [[ "$output" == *"Skipping legacy software-factory-canary#5"* ]]
  [[ "$output" == *"Skipping legacy software-factory#6"* ]]
  [[ "$output" != *"Re-triggering"* ]]
  [[ "$output" != *"pre-migration issue"* ]]
}
