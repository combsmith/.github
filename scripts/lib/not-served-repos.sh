#!/usr/bin/env bash
# Repos the org standard does not serve at all — shared by
# deploy-standard-workflows.sh (the sweep never touches them, #1334) and
# compliance-audit.sh (the audit files no findings or issues there, #1343,
# #1352), so the two never disagree about which repos are in scope.
#
# This is a different thing from the deploy sweep's SKIP_REPOS. A SKIP_REPO is
# inside the standard and self-manages it, so every required workflow on it must
# be reconciled (SKIP_OVERRIDES or SKIP_SELF_MANAGED, see
# reconcile_skip_repo_required_workflows). A repo here is outside the standard by
# a recorded decision of the Maintainer: it receives no stub, takes no opt-in, is
# not part of that reconciliation, and is not audited.
#   software-factory        — where the replacement for this fleet is built. Its
#                             design keeps the two apart (no owner-account token,
#                             none of the fleet's workflows), and its own workflow
#                             rules refuse every stub. A sync PR opened there on
#                             2026-10-12 was closed unmerged; its departures are
#                             recorded in its docs/decisions/0014.
#   software-factory-canary — throwaway repo for that project's platform trials.
# The Scorecard and SonarCloud audits do not read this list yet.
NOT_SERVED_REPOS=("software-factory" "software-factory-canary")

# True if <repo> is in NOT_SERVED_REPOS.
is_not_served_repo() {
  local repo s
  # GitHub repo names are case-insensitive; compare lowercased.
  repo=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for s in "${NOT_SERVED_REPOS[@]}"; do
    [[ "$repo" == "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" ]] && return 0
  done
  return 1
}
