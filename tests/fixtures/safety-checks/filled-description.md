## Problem

The compliance audit script crashed on repos without a default branch set.
Repro: `scripts/compliance-audit.sh --repo petry-projects/empty-fixture`.

## Risk

Low. The fix is a two-line guard around a `jq` expression that was dereferencing
a null default_branch; no schema change, no state migration.

## Test Plan

Added a bats fixture covering the null-default-branch case to
`tests/test_safety_checks.bats`; existing cases stay green. Ran the full suite
locally.

## Rollback

Revert this commit; the pre-change path was identical except for the guard.
No cleanup needed.

## Monitoring

The daily `compliance-audit-and-improvement` workflow writes a run summary
that will light up on the next cron tick if the guard regresses.
