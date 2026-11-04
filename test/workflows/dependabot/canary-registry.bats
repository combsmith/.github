#!/usr/bin/env bats
# The Dependabot reusables execute .github/scripts/dependabot/ at their pinned
# channel tag, so a change there alone must count for autocut and drift
# (canary-rollout.sh `_watched_paths` and `_autocut_signal_paths`).

load 'helpers/setup'

ORCH="${TT_REPO_ROOT}/scripts/canary-rollout.sh"
RINGS="${TT_REPO_ROOT}/standards/canary-rings.json"

@test "registry: both Dependabot agents watch the gate scripts" {
  local agent
  for agent in dependabot-automerge dependabot-rebase; do
    run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH'; _watched_paths $agent"
    [ "$status" -eq 0 ]
    [[ "$output" == *".github/scripts/dependabot/"* ]] || { echo "$agent: $output"; return 1; }
    run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH'; _autocut_signal_paths $agent"
    [ "$status" -eq 0 ]
    [[ "$output" == *".github/scripts/dependabot/"* ]] || { echo "$agent: $output"; return 1; }
  done
}
