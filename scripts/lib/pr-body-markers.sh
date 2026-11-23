#!/usr/bin/env bash
# pr-body-markers.sh — pure, side-effect-free checks on a pull request's title and body
# (issue #1571, under the prose ADR in #1565). No external calls; safe to `source` from the
# CLI (scripts/check-pr-body-markers.sh) or a bats test.
#
# Once a repo's squash message is the pull request body (#1568), the body lands on main as the
# commit message. Two markers in it then act on their own:
#   - A `BREAKING CHANGE:` line. The canary autocut no longer reads it (#1571): only the title's
#     `!` marks a breaking change. A body that carries the footer without the `!` would ship a
#     breaking change as a minor or a patch, so it is refused.
#   - A skip-CI marker. GitHub skips the push workflows for a commit whose message holds one, so
#     the merge would land on main unchecked.

# pr_title_marks_breaking <title> — 0 when the title is a conventional-commit `!` subject
# (`type!:` or `type(scope)!:`), the same form the autocut reads.
pr_title_marks_breaking() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]+(\([^\)]*\))?!: ]]
}

# pr_body_has_breaking_footer <body> — 0 when a line of the body starts (after optional
# indentation) with `BREAKING CHANGE:` or `BREAKING-CHANGE:`. HTML comments are not exempt: a
# body squash message keeps them, so the line reaches main all the same.
pr_body_has_breaking_footer() {
  printf '%s\n' "${1:-}" | grep -qE '^[[:space:]]*BREAKING[ -]CHANGE:'
}

# pr_skip_ci_markers <text> — print each skip-CI marker found in <text>, one per line, as it
# appears (case-insensitive match). Covers the five bracket markers GitHub honours and the
# `skip-checks: true` trailer.
pr_skip_ci_markers() {
  printf '%s\n' "${1:-}" | grep -oiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|^[[:space:]]*skip-checks:[[:space:]]*true' \
    | sed -E 's/^[[:space:]]+//' || true
}

# pr_body_marker_findings <title> <body> — print one finding per line; return 1 when there is
# any, 0 when the title and body are clean.
pr_body_marker_findings() {
  local title="${1:-}" body="${2:-}" found=0 marker
  if pr_body_has_breaking_footer "$body" && ! pr_title_marks_breaking "$title"; then
    printf '%s\n' "breaking-footer-without-bang: the body has a BREAKING CHANGE: line but the title has no '!'. Put '!' after the type or scope in the title (feat(area)!: ...), or drop the line."
    found=1
  fi
  while IFS= read -r marker; do
    [[ -n "$marker" ]] || continue
    printf '%s\n' "skip-ci-marker: '$marker' in the title or body would skip the checks on main once this is the squash message. Remove it."
    found=1
  done < <(pr_skip_ci_markers "$title"$'\n'"$body")
  return "$found"
}
