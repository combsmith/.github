#!/usr/bin/env bats
# Tests for scripts/lib/dismiss-stale-bot-reviews.sh — the PURE decision core for
# the dismiss-stale-bot-reviews workflow (#1115).
#
# The contract the workflow enforces: a bot's CHANGES_REQUESTED review is NOT
# cleared by GitHub's dismiss_stale_reviews_on_push (that only dismisses stale
# *approvals*), so it persists on a superseded commit and blocks reviewDecision
# forever. This core decides which reviews to dismiss, and MUST:
#   - dismiss an allow-listed bot's CHANGES_REQUESTED review that sits on a
#     commit that is NO LONGER the PR head (superseded), and
#   - NOT dismiss it when the review is on the current head (still valid), and
#   - NEVER touch a human review (bot-only by design, #1115 out-of-scope), nor a
#     non-allow-listed bot, nor any non-CHANGES_REQUESTED state.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"

setup() {
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/lib/dismiss-stale-bot-reviews.sh"
}

HEAD="8e5bc8db"   # current PR head (committed after the blocking review)
OLD="aca48dc4"    # the commit the stale review sits on (superseded)

# ── dsbr_should_dismiss — the core AC #5 decision ────────────────────────────

@test "dismiss: allow-listed bot CHANGES_REQUESTED on a superseded commit" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot
  [ "$status" -eq 0 ]
}

@test "keep: allow-listed bot CHANGES_REQUESTED on the CURRENT head (still valid)" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$HEAD" "$HEAD" "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "keep: a human CHANGES_REQUESTED on a superseded commit is never dismissed" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "don-petry" User
  [ "$status" -eq 1 ]
}

@test "keep: a non-allow-listed bot is never dismissed even when superseded" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "some-random" Bot
  [ "$status" -eq 1 ]
}

@test "keep: an APPROVED review on a superseded commit is not dismissed" {
  run dsbr_should_dismiss APPROVED "$OLD" "$HEAD" "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "keep: a COMMENTED review is not dismissed" {
  run dsbr_should_dismiss COMMENTED "$OLD" "$HEAD" "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "keep: empty head oid is a no-op (fail-closed, cannot prove superseded)" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "" "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "keep: empty review oid is a no-op (fail-closed)" {
  run dsbr_should_dismiss CHANGES_REQUESTED "" "$HEAD" "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "dismiss: copilot review bot on a superseded commit" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "copilot-pull-request-reviewer" Bot
  [ "$status" -eq 0 ]
}

# ── dsbr_is_allowlisted_bot — allow-list + bot-only gate ─────────────────────

@test "allowlist: a default-list bot with Bot type is allow-listed" {
  run dsbr_is_allowlisted_bot "coderabbitai" Bot
  [ "$status" -eq 0 ]
}

@test "allowlist: a human login is NOT allow-listed even if added to the list" {
  # Bot-only gate: author_type must be Bot. A User login is rejected regardless.
  run dsbr_is_allowlisted_bot "don-petry" User "don-petry,coderabbitai"
  [ "$status" -eq 1 ]
}

@test "allowlist: an unknown bot is not allow-listed" {
  run dsbr_is_allowlisted_bot "renovate" Bot "coderabbitai"
  [ "$status" -eq 1 ]
}

@test "allowlist: explicit CSV override replaces the default list" {
  # renovate is not in the default list; supplying it via CSV allow-lists it.
  run dsbr_is_allowlisted_bot "renovate" Bot "renovate[bot]"
  [ "$status" -eq 0 ]
  # and a default-list bot is NOT accepted once an explicit CSV is supplied.
  run dsbr_is_allowlisted_bot "coderabbitai" Bot "renovate[bot]"
  [ "$status" -eq 1 ]
}

@test "allowlist: DSBR_BOT_ALLOWLIST env overrides the default list" {
  DSBR_BOT_ALLOWLIST="renovate[bot]" run dsbr_is_allowlisted_bot "renovate" Bot
  [ "$status" -eq 0 ]
  DSBR_BOT_ALLOWLIST="renovate[bot]" run dsbr_is_allowlisted_bot "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "allowlist: whitespace around CSV entries is trimmed" {
  run dsbr_is_allowlisted_bot "coderabbitai" Bot " foo[bot] , coderabbitai[bot] "
  [ "$status" -eq 0 ]
}

# ── GraphQL login form, [bot] normalization, 4th condition (open threads) ────

@test "allowlist: the GraphQL login (no [bot] suffix) matches the default list" {
  run dsbr_is_allowlisted_bot "coderabbitai" Bot
  [ "$status" -eq 0 ]
  run dsbr_is_allowlisted_bot "copilot-pull-request-reviewer" Bot
  [ "$status" -eq 0 ]
}

@test "allowlist: the REST [bot] login also matches" {
  run dsbr_is_allowlisted_bot "coderabbitai[bot]" Bot
  [ "$status" -eq 0 ]
}

@test "allowlist: a User whose login is coderabbitai is kept" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" User
  [ "$status" -eq 1 ]
}

@test "keep: an allow-listed bot's CHANGES_REQUESTED on the current head is kept" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$HEAD" "$HEAD" "coderabbitai" Bot
  [ "$status" -eq 1 ]
}

@test "threads: an open current thread by that bot keeps the review" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" $'false\tfalse\tcoderabbitai'
  [ "$status" -eq 1 ]
  # same bot, REST-form login on the thread
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" $'false\tfalse\tcoderabbitai[bot]'
  [ "$status" -eq 1 ]
}

@test "threads: a resolved thread does not keep the review" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" $'true\tfalse\tcoderabbitai'
  [ "$status" -eq 0 ]
}

@test "threads: an outdated thread does not keep the review" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" $'false\ttrue\tcoderabbitai'
  [ "$status" -eq 0 ]
}

@test "threads: an open current thread by someone else does not keep the review" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" $'false\tfalse\tdon-petry'
  [ "$status" -eq 0 ]
}

# ── hold labels (condition 5) ────────────────────────────────────────────────

@test "hold label: each of the three fixed labels is reported" {
  local h
  for h in needs-human-review dev-lead:needs-human dev-lead:hands-off; do
    run dsbr_hold_label "$h"
    [ "$status" -eq 0 ]
    [ "$output" = "$h" ]
  done
}

@test "hold label: matching is case-insensitive; the canonical name is printed" {
  run dsbr_hold_label "Needs-Human-Review"
  [ "$status" -eq 0 ]
  [ "$output" = "needs-human-review" ]
  run dsbr_hold_label "DEV-LEAD:HANDS-OFF"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead:hands-off" ]
}

@test "hold label: a longer name containing a hold label is not a hold" {
  run dsbr_hold_label $'needs-human-review-later\nxdev-lead:hands-off\ndev-lead:needs-human:2\nsize:XL'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "hold label: an empty list is not a hold" {
  run dsbr_hold_label ""
  [ "$status" -eq 1 ]
}

@test "hold label: the hold label is found when it comes last among several" {
  run dsbr_hold_label $'size:L\nbug\nstandards-sync\ndev-lead:needs-human'
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead:needs-human" ]
}

@test "hold label: the set is not narrowed by a variable" {
  DSBR_BOT_ALLOWLIST="x" DSBR_HOLD_LABELS_CSV="" run dsbr_hold_label "needs-human-review"
  [ "$status" -eq 0 ]
}

@test "dismiss: a hold label keeps an otherwise-stale review" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" "" $'size:L\nneeds-human-review'
  [ "$status" -eq 1 ]
}

@test "dismiss: a non-hold label list still dismisses" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai" Bot "" "" $'size:L\nbug'
  [ "$status" -eq 0 ]
}
