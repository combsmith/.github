#!/usr/bin/env bats
# Regression guard for #1389: the model job must not be able to write
# Discussions, so `dry_run` and the single-idea target cannot be bypassed
# from the model's own shell.
#
# The analyst runs Claude Code with the Bash tool. Every token its job holds
# is reachable from that shell (claude-code-action exports `github.token` to
# its process, and an `id-token: write` grant lets the shell mint an OIDC
# token), and any env var it is given (`DRY_RUN`, `TARGET_DISCUSSION`) can be
# changed there. So the policies are enforced by job boundaries instead:
#   - the model job (`analyze`) holds read-only permissions and only RECORDS
#     mutations (DRY_RUN pinned to 1) into a plan;
#   - a separate `publish` job with no model validates that plan against the
#     caller's own inputs and executes it (or not, on dry_run).
#
# STATIC: parses the workflow. The executor's behaviour is exercised in
# publish-mutation-plan.bats.

load 'helpers/setup'

WF="${TT_REPO_ROOT}/.github/workflows/feature-ideation-reusable.yml"

# Jobs with a claude-code-action step (the jobs that reach the model).
model_jobs() {
  yq -r '.jobs | to_entries[] | select([.value.steps[]?.uses // "" | test("anthropics/claude-code-action")] | any) | .key' "$WF"
}

@test "model job: analyze is the only job that runs the model" {
  run model_jobs
  [ "$status" -eq 0 ]
  [ "$output" = "analyze" ]
}

@test "model job: holds no write permission of any kind (no discussions: write, no id-token: write)" {
  run yq -r '.jobs.analyze.permissions | to_entries | map(select(.value != "read")) | map(select(.value != "none")) | .[] | .key + ": " + .value' "$WF"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "analyze grants: $output"; return 1; }
  # And it does declare its permissions (an absent block would inherit the caller's).
  run yq -r '.jobs.analyze.permissions | type' "$WF"
  [ "$output" = "!!map" ]
}

@test "model job: discussions access is read-only" {
  run yq -r '.jobs.analyze.permissions.discussions' "$WF"
  [ "$output" = "read" ]
}

@test "model step: DRY_RUN is pinned to 1 (the helpers only record a plan), not the caller's input" {
  run yq -r '.jobs.analyze.steps[] | select(.id == "claude") | .env.DRY_RUN' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "model job: uploads the recorded plan for the publish job" {
  run yq -r '.jobs.analyze.steps[] | select(.with.name == "mutation-plan") | .uses' "$WF"
  [ "$status" -eq 0 ]
  [[ "$output" == actions/upload-artifact@* ]]
}

@test "publish job: is the only job with discussions: write, and has no model" {
  run yq -r '.jobs | to_entries[] | select(.value.permissions.discussions == "write") | .key' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = "publish" ]
  run yq -r '.jobs.publish' "$WF"
  # An explicit `if`: errexit ignores a leading `!`, so a bare negated grep here
  # could never fail the test.
  if grep -qE 'anthropics/claude-code-action|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY' <<< "$output"; then
    echo "the publish job references the model"; return 1
  fi
  run yq -r '.jobs.publish.permissions | to_entries[] | select(.value == "write") | .key' "$WF"
  [ "$output" = "discussions" ]
}

@test "publish job: runs after analyze and downloads its plan" {
  # `needs` may be a scalar or a list. Spelled with select/tag rather than
  # `if … then … else … end`, which older yq releases cannot parse — a suite
  # run against a pinned yq v4.44.3 failed on it (#1467).
  run yq -r '.jobs.publish.needs | ((select(tag == "!!seq") | .[]), select(tag != "!!seq"))' "$WF"
  [ "$output" = "analyze" ]
  run yq -r '.jobs.publish.steps[] | select(.with.name == "mutation-plan") | .uses' "$WF"
  [[ "$output" == actions/download-artifact@* ]]
}

@test "publish job: dry_run and the target come from the caller's inputs, never from the model job" {
  local step='.jobs.publish.steps[] | select(.run != null and (.run | test("publish-mutation-plan.sh")))'
  run yq -r "${step} | .env.CALLER_DRY_RUN" "$WF"
  [ "$output" = "\${{ inputs.dry_run && '1' || '0' }}" ]
  run yq -r "${step} | .env.TARGET_DISCUSSION" "$WF"
  [ "$output" = "\${{ inputs.target_discussion || '' }}" ]
  run yq -r "${step} | .env.ENHANCE_BACKLOG" "$WF"
  [ "$output" = "\${{ inputs.enhance_backlog && '1' || '0' }}" ]
  # Nothing the model job computes may steer the publish job.
  run yq -r '.jobs.publish' "$WF"
  if grep -q 'needs.analyze.outputs' <<< "$output"; then
    echo "the publish job reads the model job's outputs"; return 1
  fi
  run yq -r '.jobs.analyze.outputs' "$WF"
  [ "$output" = "null" ]
}

@test "caller interface: inputs and secrets are unchanged (non-breaking)" {
  run yq -r '.on.workflow_call.inputs | keys | join(",")' "$WF"
  [ "$output" = "project_context,focus_area,research_depth,model,timeout_minutes,dry_run,target_discussion,enhance_backlog,tooling_ref,sources_file" ]
  run yq -r '.on.workflow_call.secrets | keys | join(",")' "$WF"
  [ "$output" = "CLAUDE_CODE_OAUTH_TOKEN" ]
}

# Re-run recognition is bound to the workflow run (#1456): each attempt saves
# what it published as an artifact of the run, even when it fails, and a re-run
# attempt reads the earlier attempts' ledgers instead of markers in comments.
@test "publish job: each attempt uploads its re-run ledger as an artifact of the run, even on failure" {
  local up='.jobs.publish.steps[] | select(.uses != null and (.uses | test("^actions/upload-artifact@")))'
  run yq -r "${up} | .if" "$WF"
  [ "$output" = "always()" ]
  run yq -r "${up} | .with.name" "$WF"
  [ "$output" = "feature-ideation-publish-ledger-\${{ github.run_attempt }}" ]
  local step='.jobs.publish.steps[] | select(.run != null and (.run | test("publish-mutation-plan.sh")))'
  run yq -r "${step} | .env.PUBLISH_LEDGER_OUT" "$WF"
  local out="$output"
  [ -n "$out" ] && [ "$out" != "null" ]
  run yq -r "${up} | .with.path" "$WF"
  [ "$output" = "$out" ]
}

@test "publish job: a re-run attempt downloads the earlier attempts' ledgers, before publishing" {
  local dl='.jobs.publish.steps[] | select(.with.pattern == "feature-ideation-publish-ledger-*")'
  run yq -r "${dl} | .uses" "$WF"
  [[ "$output" == actions/download-artifact@* ]]
  # Only a re-run has earlier attempts: a first attempt trusts no ledger at all.
  run yq -r "${dl} | .if" "$WF"
  [ "$output" = "github.run_attempt != '1'" ]
  # One directory per artifact, so no attempt's ledger overwrites another's.
  run yq -r "${dl} | .with.merge-multiple // false" "$WF"
  [ "$output" = "false" ]
  run yq -r "${dl} | .with.path" "$WF"
  local dir="$output"
  local step='.jobs.publish.steps[] | select(.run != null and (.run | test("publish-mutation-plan.sh")))'
  run yq -r "${step} | .env.PUBLISH_LEDGER_IN" "$WF"
  [ "$output" = "$dir" ]
  # The download comes before the publish step.
  local at_download at_publish
  at_download=$(yq -r '.jobs.publish.steps | to_entries[] | select(.value.with.pattern == "feature-ideation-publish-ledger-*") | .key' "$WF")
  at_publish=$(yq -r '.jobs.publish.steps | to_entries[] | select(.value.run != null and (.value.run | test("publish-mutation-plan.sh"))) | .key' "$WF")
  [ -n "$at_download" ] && [ -n "$at_publish" ] && [ "$at_download" -lt "$at_publish" ]
}
