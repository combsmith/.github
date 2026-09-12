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
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "coderabbitai[bot]" Bot
  [ "$status" -eq 0 ]
}

@test "keep: allow-listed bot CHANGES_REQUESTED on the CURRENT head (still valid)" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$HEAD" "$HEAD" "coderabbitai[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "keep: a human CHANGES_REQUESTED on a superseded commit is never dismissed" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "don-petry" User
  [ "$status" -ne 0 ]
}

@test "keep: a non-allow-listed bot is never dismissed even when superseded" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "some-random[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "keep: an APPROVED review on a superseded commit is not dismissed" {
  run dsbr_should_dismiss APPROVED "$OLD" "$HEAD" "coderabbitai[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "keep: a COMMENTED review is not dismissed" {
  run dsbr_should_dismiss COMMENTED "$OLD" "$HEAD" "coderabbitai[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "keep: empty head oid is a no-op (fail-closed, cannot prove superseded)" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "" "coderabbitai[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "keep: empty review oid is a no-op (fail-closed)" {
  run dsbr_should_dismiss CHANGES_REQUESTED "" "$HEAD" "coderabbitai[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "dismiss: copilot review bot on a superseded commit" {
  run dsbr_should_dismiss CHANGES_REQUESTED "$OLD" "$HEAD" "copilot-pull-request-reviewer[bot]" Bot
  [ "$status" -eq 0 ]
}

# ── dsbr_is_allowlisted_bot — allow-list + bot-only gate ─────────────────────

@test "allowlist: a default-list bot with Bot type is allow-listed" {
  run dsbr_is_allowlisted_bot "coderabbitai[bot]" Bot
  [ "$status" -eq 0 ]
}

@test "allowlist: a human login is NOT allow-listed even if added to the list" {
  # Bot-only gate: author_type must be Bot. A User login is rejected regardless.
  run dsbr_is_allowlisted_bot "don-petry" User "don-petry,coderabbitai[bot]"
  [ "$status" -ne 0 ]
}

@test "allowlist: an unknown bot is not allow-listed" {
  run dsbr_is_allowlisted_bot "renovate[bot]" Bot "coderabbitai[bot]"
  [ "$status" -ne 0 ]
}

@test "allowlist: explicit CSV override replaces the default list" {
  # renovate is not in the default list; supplying it via CSV allow-lists it.
  run dsbr_is_allowlisted_bot "renovate[bot]" Bot "renovate[bot]"
  [ "$status" -eq 0 ]
  # and a default-list bot is NOT accepted once an explicit CSV is supplied.
  run dsbr_is_allowlisted_bot "coderabbitai[bot]" Bot "renovate[bot]"
  [ "$status" -ne 0 ]
}

@test "allowlist: DSBR_BOT_ALLOWLIST env overrides the default list" {
  DSBR_BOT_ALLOWLIST="renovate[bot]" run dsbr_is_allowlisted_bot "renovate[bot]" Bot
  [ "$status" -eq 0 ]
  DSBR_BOT_ALLOWLIST="renovate[bot]" run dsbr_is_allowlisted_bot "coderabbitai[bot]" Bot
  [ "$status" -ne 0 ]
}

@test "allowlist: whitespace around CSV entries is trimmed" {
  run dsbr_is_allowlisted_bot "coderabbitai[bot]" Bot " foo[bot] , coderabbitai[bot] "
  [ "$status" -eq 0 ]
}
