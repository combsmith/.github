#!/usr/bin/env bash
# dismiss-stale-bot-reviews.sh (lib) — PURE decision core for the
# dismiss-stale-bot-reviews workflow (#1115).
#
# Why this exists:
#   Agent-PR merge friction (#617, blocker 3): a bot's CHANGES_REQUESTED review is
#   NOT cleared by GitHub's dismiss_stale_reviews_on_push (that only dismisses
#   stale *approvals*), so it persists on a superseded commit and blocks
#   reviewDecision even with 0 unresolved threads — until the bot re-APPROVEs or a
#   human dismisses it by hand. This core decides which reviews a workflow may
#   dismiss on its behalf.
#
# This file is side-effect-free and network-free so it can be unit-tested with
# bats (see test/workflows/dismiss-stale-bot-reviews/decision.bats). The
# orchestrator (scripts/dismiss-stale-bot-reviews.sh) sources it and acts on the
# verdict; the workflow is thin I/O glue.
#
# Decision contract: dismiss a review ONLY when ALL of the following hold —
#   1. its state is CHANGES_REQUESTED (an APPROVED/COMMENTED review never blocks);
#   2. its author is an allow-listed BOT (bot-only by design — human reviews are
#      never dismissed, #1115 out-of-scope);
#   3. it sits on a commit that is NO LONGER the PR head (superseded). A still-
#      valid finding on the current head is left in place; it returns as a fresh
#      CHANGES_REQUESTED on the new SHA when a bot re-reviews.

# Default allow-list of bot review authors whose stale CHANGES_REQUESTED reviews
# may be dismissed. Matches the AI code reviewers this org runs (CodeRabbit +
# Copilot). Override wholesale via DSBR_BOT_ALLOWLIST (comma-separated logins) or
# the optional CSV argument to the predicates below — an explicit list REPLACES
# this default so an operator has full, tight control over what may be dismissed.
DSBR_DEFAULT_ALLOWLIST=(
  "coderabbitai[bot]"
  "coderabbit[bot]"
  "copilot[bot]"
  "copilot-pull-request-reviewer[bot]"
)

# dsbr_resolve_allowlist [csv] — print the active allow-list, one login per line.
# Precedence: explicit CSV arg > DSBR_BOT_ALLOWLIST env > built-in default. A
# supplied list REPLACES the default. Entries are whitespace-trimmed so
# "a[bot], b[bot]" resolves to "a[bot]" and "b[bot]", not "a[bot]" and " b[bot]".
dsbr_resolve_allowlist() {
  local csv="${1:-${DSBR_BOT_ALLOWLIST:-}}"
  if [ -z "$csv" ]; then
    printf '%s\n' "${DSBR_DEFAULT_ALLOWLIST[@]}"
    return 0
  fi
  # Split on commas without pathname-globbing (read -a, not unquoted expansion).
  local entries=() entry
  IFS=',' read -r -a entries <<<"$csv"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"   # strip leading whitespace
    entry="${entry%"${entry##*[![:space:]]}"}"   # strip trailing whitespace
    [ -n "$entry" ] && printf '%s\n' "$entry"
  done
}

# dsbr_is_allowlisted_bot <login> <author_type> [allowlist_csv]
#   0 if the review author is an allow-listed BOT, non-zero otherwise.
#   The author_type (GraphQL review author __typename) MUST be "Bot": this is the
#   bot-only gate that guarantees a human review is never a dismissal candidate,
#   even if a human login were mistakenly present in the allow-list.
dsbr_is_allowlisted_bot() {
  local login="$1" author_type="$2" csv="${3:-}"
  [ "$author_type" = "Bot" ] || return 1
  local allowed
  while IFS= read -r allowed; do
    [ "$allowed" = "$login" ] && return 0
  done < <(dsbr_resolve_allowlist "$csv")
  return 1
}

# dsbr_should_dismiss <state> <review_oid> <head_oid> <login> <author_type> [allowlist_csv]
#   0 (dismiss) iff the review is an allow-listed bot's CHANGES_REQUESTED sitting
#   on a superseded commit; non-zero (keep) otherwise. Fail-closed: a missing
#   review_oid or head_oid cannot prove the review is superseded, so it is kept.
dsbr_should_dismiss() {
  local state="$1" review_oid="$2" head_oid="$3" login="$4" author_type="$5" csv="${6:-}"
  [ "$state" = "CHANGES_REQUESTED" ] || return 1
  [ -n "$review_oid" ] && [ -n "$head_oid" ] || return 1
  [ "$review_oid" != "$head_oid" ] || return 1
  dsbr_is_allowlisted_bot "$login" "$author_type" "$csv" || return 1
  return 0
}
