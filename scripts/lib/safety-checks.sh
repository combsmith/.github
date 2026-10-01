#!/usr/bin/env bash
# safety-checks.sh — sourceable PR-safety signal helpers.
#
# This library provides metadata-only signal functions that scripts can source
# to score or triage a pull request without executing any PR code. The first
# resident is sc_description_missing, the fix for the #1976 regression where
# an empty PR template was scored 0/5 missing — the template's own headings
# and HTML comments contain the keywords a naive grep looks for.
#
# Signal contract (shared by every sc_* helper in this file):
#   stdin / args — PR metadata only (title, body, author_association, ...).
#   stdout       — a single integer or a `key=value` line, suitable for a scorer.
#   stderr       — human-readable warnings; a signal that cannot be read MUST
#                  fail closed (return non-zero) so the caller escalates to a
#                  human rather than scoring the PR "not spam".
#
# Related: epic petry-projects/.github#1200 (spam-pr-guard), story #1202 (this
# function), story #1203 (the scorer that will consume these signals).

# ---------------------------------------------------------------------------
# Description-quality signal
# ---------------------------------------------------------------------------
# The five canonical sections expected in a PR body. The order is irrelevant
# (each is matched independently); the labels are the keys the scorer reports.
# Kept as data (not a hardcoded regex) so a future config can change the
# section set without touching the matcher — the AGENTS.md "data not code" rule.
SC_DESCRIPTION_SECTION_KEYS=(problem risk test-plan rollback monitoring)

# One case-insensitive ERE per key, matched against the heading line only.
# The keyword must START at a word boundary (so body text saying "problematic"
# does not drag the Problem section into "present"), but may extend with
# arbitrary trailing letters so plurals and variants in headings — "Risks and
# Mitigations", "Rollback Plan", "Monitoring and alerts" — still match. The
# trailing [[:alpha:]]* applies ONLY to heading matching; body-text classification
# never consults these patterns, so "problematic" in prose does not confuse it.
SC_DESCRIPTION_SECTION_PATTERNS=(
  '(^|[^[:alnum:]])problem[[:alpha:]]*([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])risk[[:alpha:]]*([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])test[-[:space:]]?plan[[:alpha:]]*([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])rollback[[:alpha:]]*([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])monitoring[[:alpha:]]*([^[:alnum:]]|$)'
)

# sc_description_missing — count how many of the five canonical sections lack
# real body text in a PR description, returning the integer on stdout.
#
# Contract:
#   stdin — the raw PR body (markdown).
#   stdout — a single integer in [0..5]; 5 means every section is empty.
#   stderr — a human-readable warning when the body cannot be read.
#
# A section is "present" iff a markdown heading matches one of the five
# SC_DESCRIPTION_SECTION_PATTERNS AND at least one non-heading, non-comment,
# non-blank line of text sits under that heading before the next heading
# (or end-of-body). The heading line itself and any HTML comment under it
# do NOT count — that is the whole point of the #1976 fix.
#
# Fail-closed: a hard read failure (cat exits non-zero) returns 1 and the
# caller must treat this as "escalate to human". An intentionally empty
# body is NOT a read failure; it is a valid 5/5 missing.
sc_description_missing() {
  local body
  if ! body="$(cat)"; then
    echo "sc_description_missing: failed to read PR body from stdin" >&2
    return 1
  fi

  local -a found=(0 0 0 0 0)
  local current=0           # 1-based index into SC_DESCRIPTION_SECTION_KEYS, or 0
  local in_comment=0        # whether we are inside a <!-- ... --> span
  local line stripped tail

  # Walk the body line by line. Each iteration either (a) continues/exits a
  # multi-line HTML comment, (b) classifies the line as a heading (opens a
  # section), or (c) treats the line as body text under the current section.
  while IFS= read -r line || [[ -n "$line" ]]; do

    # (a) Still inside a multi-line HTML comment: consume up to the closer.
    if (( in_comment )); then
      if [[ "$line" == *"-->"* ]]; then
        tail="${line#*-->}"
        in_comment=0
        # Fall through with `line` set to the post-comment tail so trailing
        # text on the same line is still inspected.
        line="$tail"
      else
        continue
      fi
    fi

    # Strip inline comments. If a comment opens but does not close on this
    # line, we flip in_comment and keep whatever text precedes the opener.
    stripped=""
    while [[ -n "$line" ]]; do
      if [[ "$line" == *"<!--"* ]]; then
        stripped+="${line%%<!--*}"
        line="${line#*<!--}"
        if [[ "$line" == *"-->"* ]]; then
          line="${line#*-->}"
        else
          line=""
          in_comment=1
        fi
      else
        stripped+="$line"
        line=""
      fi
    done

    # (b) Heading line? Record whether it matches any yet-unmet section key.
    # ATX headings only: a run of `#` followed by whitespace or end-of-line.
    if [[ "$stripped" =~ ^[[:space:]]*#+([[:space:]]|$) ]]; then
      current=0
      local lower
      lower="$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]')"
      local i
      for i in "${!SC_DESCRIPTION_SECTION_PATTERNS[@]}"; do
        if (( found[i] )); then continue; fi
        if [[ "$lower" =~ ${SC_DESCRIPTION_SECTION_PATTERNS[i]} ]]; then
          current=$((i + 1))
          break
        fi
      done
      continue
    fi

    # (c) Body text. If it's under one of the five sections AND has at least
    # one non-whitespace character, mark that section found.
    if (( current > 0 )); then
      local trimmed="${stripped#"${stripped%%[![:space:]]*}"}"
      if [[ -n "$trimmed" ]]; then
        found[current - 1]=1
      fi
    fi
  done <<<"$body"

  local miss=0 j
  for j in "${!SC_DESCRIPTION_SECTION_KEYS[@]}"; do
    if (( ! found[j] )); then miss=$((miss + 1)); fi
  done
  printf '%d\n' "$miss"
}
