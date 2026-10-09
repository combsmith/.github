#!/usr/bin/env bats
# Tests for the `model` input of the reusable feature-ideation workflow
# (issue #1210). The default must be the model FAMILY (`opus`) so the BMAD
# Analyst auto-tracks the current Opus via the Claude Code CLI's client-side
# alias resolution — a pinned version id must never be the default.

load 'helpers/setup'

WF="${TT_REPO_ROOT}/.github/workflows/feature-ideation-reusable.yml"

@test "model input: default is the opus family" {
  run yq -r '.on.workflow_call.inputs.model.default' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "model input: default is not a pinned claude-* version id" {
  run yq -r '.on.workflow_call.inputs.model.default' "$WF"
  [ "$status" -eq 0 ]
  [[ "$output" != claude-* ]]
}

@test "model input: description recommends the opus family with an id override" {
  run yq -r '.on.workflow_call.inputs.model.description' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = 'Model family (`opus` recommended - Sonnet produces shallower adversarial passes) or an explicit model id override' ]
}

@test "analyst step: model is passed via --model so the CLI resolves the family" {
  run yq -r '.jobs[].steps[]? | select(.name == "Run Claude Code — BMAD Analyst") | .with.claude_args' "$WF"
  [ "$status" -eq 0 ]
  [[ "$output" == *'--model ${{ inputs.model }}'* ]]
}

@test "analyst step: no ANTHROPIC_MODEL env bypasses the CLI's alias resolver" {
  run yq -r '.jobs[].steps[]? | select(.name == "Run Claude Code — BMAD Analyst") | .env // {} | has("ANTHROPIC_MODEL")' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}
