#!/usr/bin/env bats
# Unit tests for scripts/lib/agent-md-xref.sh — the shared AGENTS.md
# cross-reference verdict used by the fleet audit and agent-shield-reusable.yml.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/agent-md-xref.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/agent-shield-reusable.yml"

setup() { source "$LIB"; }

@test "xref: body naming AGENTS.md passes" {
  run agent_md_references_agents <<< "See [AGENTS.md](AGENTS.md)."
  [ "$status" -eq 0 ]
}

@test "xref: match is case-insensitive" {
  run agent_md_references_agents <<< "see agents.md"
  [ "$status" -eq 0 ]
}

@test "xref: punctuation cannot stand in for the dot (fixed-string match)" {
  run agent_md_references_agents <<< "AGENTSxmd AGENTS-md"
  [ "$status" -ne 0 ]
}

@test "xref: empty body fails" {
  run agent_md_references_agents < /dev/null
  [ "$status" -ne 0 ]
}

@test "reusable workflow delegates the verdict to the helper for CLAUDE.md and GEMINI.md" {
  grep -q 'agent_md_references_agents' "$WORKFLOW"
  grep -q 'scripts/lib/agent-md-xref.sh' "$WORKFLOW"
  ! grep -q "grep -qFi 'AGENTS.md'" "$WORKFLOW"
}
