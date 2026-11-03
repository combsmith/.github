#!/usr/bin/env bats
# Tests for the credential wiring of the canonical caller stub
# standards/workflows/feature-ideation.yml (issue #836, Part A).
#
# The reusable `secrets:` block passes CLAUDE_CODE_OAUTH_TOKEN (not a PAT) and
# MUST stay untouched. The redispatch job's credential is in trusted-trigger.bats.

load 'helpers/setup'

STUB="${TT_REPO_ROOT}/standards/workflows/feature-ideation.yml"

@test "stub: reusable secrets block still passes CLAUDE_CODE_OAUTH_TOKEN unchanged" {
  run yq -r '.jobs.ideate.secrets.CLAUDE_CODE_OAUTH_TOKEN' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}' ]
}

@test "stub: reusable secrets block carries no GH_PAT ref (PAT is not passed to the reusable)" {
  run yq -r '.jobs.ideate.secrets | keys | .[]' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = 'CLAUDE_CODE_OAUTH_TOKEN' ]
}
