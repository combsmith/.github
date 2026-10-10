#!/usr/bin/env bash
# Update gate for the auto-rebase reusable workflow (issue #1272).
#
# Pure decision (no external calls, no sleeps): decides whether a PR that is
# BEHIND its base should actually be updated.
# Being merely behind blocks nothing unless the base branch's effective rules
# require branches to be up to date (strict required status checks — from
# rulesets or classic protection). Merge-queue membership and auto-merge are
# deliberately NOT conditions: with the strict policy off, being behind does not
# stop a PR entering the queue, and the queue builds its own merge commit.
#
# A conflicting PR is still attempted so the reusable's existing conflict
# notice → dev-lead recovery path fires. Anything that cannot be read fails
# safe to the pre-gate behaviour (update) and says so.
#
# Facts are gathered by lib/gate-facts.sh (the I/O glue).
#
# Tested by test/workflows/auto-rebase/update-gate.bats.
# Contract: see .github/scripts/auto-rebase/README.md

# auto_rebase_gate_decide STRICT MERGEABLE
#   Pure decision. Prints the reason and returns:
#     0  update (strict is required, the PR conflicts, or the gate could not be
#        evaluated — fail safe to the pre-gate behaviour)
#     1  skip (strict up-to-date not required)
#     3  undecided: strict is not required and mergeability is not yet computed
auto_rebase_gate_decide() {
  local strict="$1" mergeable="$2"

  if [[ "$strict" == "true" ]]; then
    echo "base branch rules require branches to be up to date"
    return 0
  fi
  if [[ "$strict" != "false" ]]; then
    echo "could not evaluate (base branch rules unreadable) — updating as before"
    return 0
  fi
  case "$mergeable" in
    CONFLICTING)
      echo "merge conflict — attempting so the conflict notice is posted"
      return 0
      ;;
    MERGEABLE)
      echo "none applied (strict up-to-date not required)"
      return 1
      ;;
    *)
      echo "mergeability not yet computed"
      return 3
      ;;
  esac
}
