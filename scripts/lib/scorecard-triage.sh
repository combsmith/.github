#!/usr/bin/env bash
# scorecard-triage.sh — pure, side-effect-free decision helpers for the weekly
# OpenSSF Scorecard review (.github/workflows/org-scorecard.yml). No network or
# gh calls; the only dependency is jq, so the same functions run from the
# workflow and from test/scripts/scorecard/scorecard-triage.bats.
#
# The workflow gathers facts (one Scorecard check row as JSON, the open issue's
# current title) and asks these helpers for the verdict; it then acts on the
# answer with gh. Keeping the decisions here means a regression in the
# exemption or the title format fails a bats run pre-merge instead of silently
# mis-triaging every public repo on the next Monday scan (see #709 and the
# `--show-details` regression that left that exemption dead code).

# scorecard_pinned_actions_only <check_row_json>
#
# Return 0 (suppress) when a Pinned-Dependencies check row carries at least one
# "not pinned by hash" detail AND every such detail names a GitHubAction. This
# is the first-party channel-tag exemption from #709: third-party action pinning
# is enforced by compliance-audit.sh and first-party refs deliberately float.
#
# Return 1 (keep the issue) in every other case — a non-Actions gap
# (containerImage / pipCommand / npmCommand / goCommand …), no recognisable
# detail lines, or a missing/null `.details` array. The last case is what the
# workflow produces when scorecard runs WITHOUT `--show-details`: erring toward
# keeping the issue is the intended safe failure mode, so callers must pass
# `--show-details` for the exemption to ever fire.
scorecard_pinned_actions_only() {
  local row="$1" total non_action
  total="$(jq -r \
    '[.details // [] | .[] | select(test("not pinned by hash"; "i"))] | length' \
    <<<"$row" 2>/dev/null)" || return 1
  non_action="$(jq -r \
    '[.details // [] | .[] | select(test("not pinned by hash"; "i")) | select(test("GitHubAction"; "i") | not)] | length' \
    <<<"$row" 2>/dev/null)" || return 1
  [ "${total:-0}" -gt 0 ] && [ "${non_action:-1}" -eq 0 ]
}

# scorecard_issue_prefix <check_name>
#
# The stable, score-free part of a finding's issue title. The workflow searches
# open `scorecard`-labelled issues with `startswith(<prefix>)`, so the prefix —
# not the full title — is the identity of an issue across weekly runs.
scorecard_issue_prefix() {
  printf 'Scorecard: %s' "$1"
}

# scorecard_issue_title <check_name> <score>
#
# The full issue title for a finding at a given score, e.g.
# "Scorecard: Branch-Protection (8/10)".
scorecard_issue_title() {
  printf '%s (%s/10)' "$(scorecard_issue_prefix "$1")" "$2"
}

# scorecard_title_is_current <current_title> <check_name> <score>
#
# Return 0 when an existing issue's title already carries this week's score,
# 1 when it is stale and should be edited. Issues are created with the score
# in the title and then live for months; without this check they keep saying
# "(0/10)" long after the score has moved (repo-template#1, #6).
scorecard_title_is_current() {
  [ "$1" = "$(scorecard_issue_title "$2" "$3")" ]
}
