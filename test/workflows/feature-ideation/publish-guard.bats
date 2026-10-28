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
  ! grep -qE 'anthropics/claude-code-action|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY' <<< "$output"
  run yq -r '.jobs.publish.permissions | to_entries[] | select(.value == "write") | .key' "$WF"
  [ "$output" = "discussions" ]
}

@test "publish job: runs after analyze and downloads its plan" {
  run yq -r '.jobs.publish.needs | (if type == "!!seq" then .[] else . end)' "$WF"
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
  ! grep -q 'needs.analyze.outputs' <<< "$output"
  run yq -r '.jobs.analyze.outputs' "$WF"
  [ "$output" = "null" ]
}

@test "caller interface: inputs and secrets are unchanged (non-breaking)" {
  run yq -r '.on.workflow_call.inputs | keys | join(",")' "$WF"
  [ "$output" = "project_context,focus_area,research_depth,model,timeout_minutes,dry_run,target_discussion,enhance_backlog,tooling_ref,sources_file" ]
  run yq -r '.on.workflow_call.secrets | keys | join(",")' "$WF"
  [ "$output" = "CLAUDE_CODE_OAUTH_TOKEN" ]
}
