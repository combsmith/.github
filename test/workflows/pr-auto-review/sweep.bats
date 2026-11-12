#!/usr/bin/env bats
# Tests for pr_auto_review_sweep_candidates in
# .github/scripts/pr-auto-review/lib/sweep.sh
#
# The catch-up sweep (issue #868) enumerates open standards-sync PRs and
# re-invokes the ready-check → dispatch path for the ones that went green
# without a fresh event. pr_auto_review_sweep_candidates is the pure,
# side-effect-free selection + back-pressure core: given the PR list the sweep
# workflow fetched (`gh search prs --json url,isDraft`), it emits the bounded
# set of candidate PR URLs — drafts dropped, capped at MAX per run so a bulk
# convergence drains at a throttled rate rather than firing all dispatches at
# once (back-pressure, acceptance criterion for donpetry-bot token capacity).
#
# The per-PR readiness decision itself is NOT re-implemented here: the sweep
# reuses pr_auto_review_ready, so the #680 cancelled/superseded-non-required
# tolerance is inherited verbatim (see ready.bats / ready-check.bats).

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/sweep.sh"
}

# Three open PRs, the middle one a draft.
LIST='[
  {"url":"https://github.com/combsmith/repo-a/pull/1","isDraft":false},
  {"url":"https://github.com/combsmith/repo-b/pull/2","isDraft":true},
  {"url":"https://github.com/combsmith/repo-c/pull/3","isDraft":false}
]'

# ── draft exclusion ──────────────────────────────────────────────────────────

@test "candidates: drafts are excluded, non-drafts kept in input order" {
  run pr_auto_review_sweep_candidates 10 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "https://github.com/combsmith/repo-a/pull/1" ]
  [ "${lines[1]}" = "https://github.com/combsmith/repo-c/pull/3" ]
  [ "${#lines[@]}" -eq 2 ]
}

# ── back-pressure: bounded number per run ────────────────────────────────────

@test "candidates: capped at MAX (back-pressure), taking the first N non-drafts" {
  run pr_auto_review_sweep_candidates 1 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "https://github.com/combsmith/repo-a/pull/1" ]
}

@test "candidates: MAX larger than the candidate count returns all non-drafts" {
  run pr_auto_review_sweep_candidates 99 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "candidates: MAX of 0 (or negative) emits nothing" {
  run pr_auto_review_sweep_candidates 0 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]

  run pr_auto_review_sweep_candidates -5 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "candidates: non-numeric MAX emits nothing (defensive)" {
  run pr_auto_review_sweep_candidates "abc" <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

# ── empty / malformed input ──────────────────────────────────────────────────

@test "candidates: empty PR list emits nothing" {
  run pr_auto_review_sweep_candidates 10 <<<'[]'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "candidates: empty stdin emits nothing" {
  run pr_auto_review_sweep_candidates 10 < /dev/null
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "candidates: non-array API error body emits nothing" {
  run pr_auto_review_sweep_candidates 10 <<<'{"message":"Not Found"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "candidates: an object missing isDraft is treated as non-draft" {
  run pr_auto_review_sweep_candidates 10 <<<'[{"url":"https://github.com/combsmith/repo-a/pull/7"}]'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "https://github.com/combsmith/repo-a/pull/7" ]
}

@test "candidates: all drafts → nothing" {
  run pr_auto_review_sweep_candidates 10 <<<'[{"url":"https://github.com/combsmith/repo-a/pull/1","isDraft":true}]'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

# ── zero-padded MAX is normalized to base 10 (not octal) ─────────────────────

@test "candidates: zero-padded MAX 08 is parsed as decimal 8, not octal" {
  run pr_auto_review_sweep_candidates 08 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "candidates: zero-padded MAX 09 is parsed as decimal 9, not octal" {
  run pr_auto_review_sweep_candidates 09 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "candidates: zero-padded MAX 01 caps at one candidate" {
  run pr_auto_review_sweep_candidates 01 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "https://github.com/combsmith/repo-a/pull/1" ]
}

@test "candidates: MAX 000 normalizes to 0 and emits nothing" {
  run pr_auto_review_sweep_candidates 000 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "candidates: jq receives the normalized MAX via --argjson" {
  # Wrap jq to record the value bound to --argjson max (JSON forbids leading zeros).
  jq() {
    local i
    for ((i = 1; i < $#; i++)); do
      if [[ "${!i}" == "--argjson" ]]; then
        local n=$((i + 1)) v=$((i + 2))
        echo "${!n}=${!v}" >"$BATS_TEST_TMPDIR/argjson"
      fi
    done
    command jq "$@"
  }
  run pr_auto_review_sweep_candidates 08 <<<"$LIST"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/argjson")" = "max=8" ]
}
