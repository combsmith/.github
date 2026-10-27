#!/usr/bin/env bash
# agent-md-xref.sh — pure verdict for the agent-file cross-reference rule.
#
# Sourced by scripts/compliance-audit.sh (check_claude_md / check_gemini_md)
# and fetched by .github/workflows/agent-shield-reusable.yml ("Validate
# cross-references"), so the fleet audit and the per-repo CI gate share ONE
# decision. Bats coverage: test/scripts/compliance-audit/agent-md-xref.bats.
#
#   agent_md_references_agents  — reads a file body on stdin; exit 0 when it
#                                 contains the literal filename AGENTS.md
#                                 (case-insensitive, fixed-string match, so
#                                 "AGENTS-md" or "AGENTSxmd" never satisfy it).
#                                 Empty input is non-compliant (exit 1).

agent_md_references_agents() {
  grep -qFi 'AGENTS.md'
}
