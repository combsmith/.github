## Problem

The PR-description safety check had no reusable helper for counting which
required sections of a description are missing or left as template filler.

## Risk

Low. The change adds a new shell library and fixtures only; no existing
workflow sources it yet, so nothing in production behavior changes.

## Test Plan

Added bats cases in `tests/test_safety_checks.bats` that run the helper against
the fixtures in this directory; the full suite passes locally.

## Rollback

Revert this commit; nothing else depends on the new library.
No cleanup needed.

## Monitoring

The `safety-checks-tests` workflow runs the bats suite on every change to the
library and will fail if the behavior regresses.
