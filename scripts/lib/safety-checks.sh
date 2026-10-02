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
# The test-plan key additionally accepts the bare verb forms real PRs use —
# "Tests", "Testing", "How to test" — with the "plan" segment optional, so a
# "## Tests" heading is not mis-flagged as a missing test section.
SC_DESCRIPTION_SECTION_PATTERNS=(
  '(^|[^[:alnum:]])problems?([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])risks?([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])test(s|ing)?([[:space:]-]?plan(s)?)?([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])rollback(s)?([^[:alnum:]]|$)'
  '(^|[^[:alnum:]])monitoring([^[:alnum:]]|$)'
)

# Lines whose entire trimmed-and-lowercased content matches one of these forms
# count as placeholder filler, not real body text. Keeping the list short and
# literal — generic heuristics (e.g. "any line that is just checkbox markers")
# would over-match genuine content. "_No response_" is GitHub's own default
# when an issue-form field is left empty, and the two spelling variants cover
# what the PR-form family actually emits.
SC_DESCRIPTION_PLACEHOLDER_FORMS=(
  '_no response_'
  'no response'
  '*no response*'
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
# non-blank, non-structural line of real text sits under that heading before
# the next heading (or end-of-body). Lines inside fenced code blocks, HTML
# comments, Markdown thematic breaks (`---`, `***`, `___`), and known
# placeholder forms (`_No response_`) do NOT count — the #1976 regression
# class includes a draft that looks filled because every section carries a
# default placeholder and a horizontal rule between sections.
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
  local -a current=()       # 0-based indexes of sections the last heading opened
  local in_comment=0        # whether we are inside a <!-- ... --> span
  local in_fence=0          # whether we are inside a ``` or ~~~ fenced block
  local fence_char=""       # the backtick/tilde that opened the current fence
  local fence_len=0         # how many of fence_char the opening line held
  local line stripped tail

  # Walk the body line by line. Each iteration either (a) continues/exits a
  # multi-line HTML comment, (b) continues/exits a fenced code block,
  # (c) classifies the line as a heading (opens a section), or (d) treats
  # the line as body text under the current section (filtering out structural
  # and placeholder lines).
  while IFS= read -r line || [[ -n "$line" ]]; do

    # (a1) Inside a fenced code block — every line is code until the matching
    # close. Fences dominate: HTML-comment markers inside code are code, and a
    # `#` prefix inside code is not a heading. Same regression class as #1976
    # if we skip this (a `# problem` inside a ``` block would otherwise open
    # the Problem section).
    if (( in_fence )); then
      _sc_is_fence_close "$line" "$fence_char" "$fence_len" && {
        in_fence=0
        fence_char=""
        fence_len=0
      }
      continue
    fi

    # (a2) Still inside a multi-line HTML comment: consume up to the closer.
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

    # (b) Fence open? Record the delimiter and skip. CommonMark allows an info
    # string after the opening fence (e.g. ```` ```bash ````) — we don't care
    # what it is; the whole line still just opens the fence. A code block IS
    # real content, so credit every open section BEFORE skipping the fence
    # body (otherwise a section whose only content is a code snippet would
    # score as missing — exactly the opposite of what we want).
    local fence_open_char
    fence_open_char="$(_sc_fence_open_char "$stripped")"
    if [[ -n "$fence_open_char" ]]; then
      fence_char="$fence_open_char"
      fence_len="$(_sc_fence_run_length "$stripped" "$fence_char")"
      in_fence=1
      if (( ${#current[@]} > 0 )); then
        local idx
        for idx in "${current[@]}"; do
          found[idx]=1
        done
      fi
      continue
    fi

    # (c) Heading line? Record EVERY yet-unmet section key it matches. A single
    # heading can open more than one section ("## Risk and Rollback", "## Problem
    # / Risk"), so we collect all matching indexes rather than stopping at the
    # first — each section is matched independently per the contract above.
    # ATX headings per CommonMark: at most three leading SPACES (a leading tab is
    # four-column indentation, i.e. an indented code block), then one-to-six `#`
    # (seven or more is not a heading) followed by whitespace or end-of-line. So
    # a line like `    # problem` or `\t## problem` must NOT register as a heading.
    local heading_regex='^ {0,3}#{1,6}([[:space:]]|$)'
    if [[ "$stripped" =~ $heading_regex ]]; then
      current=()
      # Native lowercase (bash 4+) — avoids a per-line subshell + tr fork.
      local lower="${stripped,,}"
      local i
      for i in "${!SC_DESCRIPTION_SECTION_PATTERNS[@]}"; do
        if (( found[i] )); then continue; fi
        if [[ "$lower" =~ ${SC_DESCRIPTION_SECTION_PATTERNS[i]} ]]; then
          current+=("$i")
        fi
      done
      continue
    fi

    # (d) Body text. If it sits under one or more open sections AND has at
    # least one non-whitespace character AND is neither a Markdown thematic
    # break nor a known placeholder form, mark every one of those sections
    # found. The thematic-break / placeholder filters are what keep a draft
    # that reads as filled-but-empty (every section a `_No response_` under a
    # `---` divider) from scoring 0/5 missing.
    if (( ${#current[@]} > 0 )); then
      local non_space_regex='[^[:space:]]'
      if [[ "$stripped" =~ $non_space_regex ]] \
        && ! _sc_is_thematic_break "$stripped" \
        && ! _sc_is_placeholder "$stripped"; then
        local idx
        for idx in "${current[@]}"; do
          found[idx]=1
        done
      fi
    fi
  done <<<"$body"

  local miss=0 j
  for j in "${!SC_DESCRIPTION_SECTION_KEYS[@]}"; do
    if (( ! found[j] )); then miss=$((miss + 1)); fi
  done
  printf '%d\n' "$miss"
}

# ---------------------------------------------------------------------------
# Private helpers (prefix _sc_ marks them off the public sc_* surface)
# ---------------------------------------------------------------------------

# _sc_fence_open_char — return the fence delimiter character (` or ~) if the
# argument is a CommonMark fenced-code-block OPEN line, else empty. CommonMark
# requires three or more of the same delimiter at columns 0..3; anything may
# follow as an info string.
_sc_fence_open_char() {
  local s="$1"
  local backtick_open_regex='^ {0,3}`{3,}'
  local tilde_open_regex='^ {0,3}~{3,}'
  if [[ "$s" =~ $backtick_open_regex ]]; then
    printf '`'
    return 0
  fi
  if [[ "$s" =~ $tilde_open_regex ]]; then
    printf '~'
    return 0
  fi
}

# _sc_fence_run_length — count the opening fence delimiter run on a line that
# already matched _sc_fence_open_char. We walk past the leading whitespace and
# count the delimiter run; this is the minimum length the closing fence must
# match or exceed per CommonMark.
_sc_fence_run_length() {
  local s="$1" ch="$2"
  local trimmed="${s#"${s%%[![:space:]]*}"}"
  local n=0
  while [[ "${trimmed:$n:1}" == "$ch" ]]; do
    n=$((n + 1))
  done
  printf '%d' "$n"
}

# _sc_is_fence_close — return true iff the line is a valid closing fence for
# the currently-open fence. CommonMark: at most three leading spaces, then at
# least fence_len copies of fence_char, optional trailing whitespace, nothing
# else.
_sc_is_fence_close() {
  local s="$1" ch="$2" needed="$3"
  local trimmed="${s#"${s%%[![:space:]]*}"}"
  # Strip trailing whitespace.
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  # The trimmed line must be ch repeated at least `needed` times, nothing else.
  (( ${#trimmed} >= needed )) || return 1
  local i
  for (( i = 0; i < ${#trimmed}; i++ )); do
    [[ "${trimmed:i:1}" == "$ch" ]] || return 1
  done
  return 0
}

# _sc_is_thematic_break — true iff the line is a CommonMark thematic break:
# at most three leading spaces, then three or more of `-`, `*`, or `_`
# (all the same character), optionally separated by any amount of whitespace,
# and nothing else on the line.
_sc_is_thematic_break() {
  local s="$1"
  local trimmed="${s#"${s%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  (( ${#trimmed} >= 3 )) || return 1
  local first="${trimmed:0:1}"
  case "$first" in
    -|\*|_) ;;
    *) return 1 ;;
  esac
  local count=0 ch i
  for (( i = 0; i < ${#trimmed}; i++ )); do
    ch="${trimmed:i:1}"
    if [[ "$ch" == "$first" ]]; then
      count=$((count + 1))
    elif [[ "$ch" != " " && "$ch" != $'\t' ]]; then
      return 1
    fi
  done
  (( count >= 3 ))
}

# _sc_is_placeholder — true iff the stripped line, trimmed and lowercased,
# matches any of SC_DESCRIPTION_PLACEHOLDER_FORMS. These are the GitHub
# issue-form defaults that look like body text but mean "contributor skipped
# this field".
_sc_is_placeholder() {
  local s="$1"
  local trimmed="${s#"${s%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  local lower="${trimmed,,}"
  local form
  for form in "${SC_DESCRIPTION_PLACEHOLDER_FORMS[@]}"; do
    [[ "$lower" == "$form" ]] && return 0
  done
  return 1
}
