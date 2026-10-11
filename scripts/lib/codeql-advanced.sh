# shellcheck shell=bash
# scripts/lib/codeql-advanced.sh — repos approved for advanced CodeQL setup
#
# The org standard is GitHub-managed CodeQL default setup, with no per-repo
# workflow file (standards/ci-standards.md §2). This library holds the list of
# repos approved to run an inline `.github/workflows/codeql.yml` instead, and
# the predicate both consumers use to read it:
#
#   scripts/apply-repo-settings.sh   — must NOT re-enable default setup on a
#                                      listed repo (GitHub rejects the advanced
#                                      upload while default setup is enabled).
#   scripts/compliance-audit.sh      — must NOT flag a listed repo's codeql.yml
#                                      as drift, and instead checks the workflow
#                                      is present.
#
# One list, so the applier and the audit cannot disagree about a repo.
#
# Adding a repo: each entry needs a reason default setup cannot serve, recorded
# in the "Escape hatch" part of standards/ci-standards.md §2 and in the header
# of that repo's codeql.yml.
#
# This library is `set -euo pipefail`-safe and does not call `set` itself.

# Bare repo names (no org prefix), matching how both consumers name repos.
#   .github          — adopting a merge queue; `CodeQL` is a required check and
#                      default setup cannot report on `merge_group`.
#   .github-private  — merge queue enabled 2026-10-09, same reason.
CODEQL_ADVANCED_EXCEPTIONS=(".github" ".github-private")

# codeql_advanced_exception <repo>
#   Returns 0 when <repo> is approved for advanced CodeQL setup, 1 otherwise.
codeql_advanced_exception() {
  local repo="$1" exception
  for exception in "${CODEQL_ADVANCED_EXCEPTIONS[@]}"; do
    [[ "$repo" == "$exception" ]] && return 0
  done
  return 1
}
