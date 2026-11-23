#!/usr/bin/env bats
# Tests for scripts/lib/pr-body-markers.sh and scripts/check-pr-body-markers.sh (issue #1571).
# Once a repo's squash message is the pull request body (#1568), a BREAKING CHANGE: line without
# '!' in the title would ship a break as a minor (the autocut reads only the title's '!'), and a
# skip-CI marker would land the merge on main unchecked. The check refuses both.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/pr-body-markers.sh"
  CHECK="$REPO_ROOT/scripts/check-pr-body-markers.sh"
}

@test "title: type! and type(scope)! mark a breaking change (#1571)" {
  pr_title_marks_breaking 'feat!: drop the legacy input (#1)'
  pr_title_marks_breaking 'feat(canary)!: drop the legacy input (#1)'
  pr_title_marks_breaking 'fix(dev-lead)!: rename the token secret (#1)'
}

@test "title: no bang, a bang after the colon, or a bang before the scope is not breaking (#1571)" {
  run pr_title_marks_breaking 'feat(canary): add an input (#1)'
  [ "$status" -ne 0 ]
  run pr_title_marks_breaking 'canary: add an input! (#1)'
  [ "$status" -ne 0 ]
  run pr_title_marks_breaking 'feat!(canary): add an input (#1)'
  [ "$status" -ne 0 ]
  run pr_title_marks_breaking ''
  [ "$status" -ne 0 ]
}

@test "body: a BREAKING CHANGE or BREAKING-CHANGE line is found, indented or not (#1571)" {
  pr_body_has_breaking_footer $'## Why\n\nx\n\nBREAKING CHANGE: the input is required'
  pr_body_has_breaking_footer $'x\n  BREAKING-CHANGE: renamed'
  pr_body_has_breaking_footer $'<!--\nBREAKING CHANGE: inside a comment still lands on main\n-->'
}

@test "body: the words mid-line are not a footer (#1571)" {
  run pr_body_has_breaking_footer $'A `BREAKING CHANGE:` line here is not read.'
  [ "$status" -ne 0 ]
  run pr_body_has_breaking_footer $'no footer here\nbreaking change: lower case is not a footer'
  [ "$status" -ne 0 ]
  run pr_body_has_breaking_footer ''
  [ "$status" -ne 0 ]
}

@test "findings: a footer without the title's bang is refused (#1571)" {
  run pr_body_marker_findings 'feat(canary): make the input required (#1)' $'## Why\n\nx\n\nBREAKING CHANGE: the input is required'
  [ "$status" -eq 1 ]
  [[ "$output" == "breaking-footer-without-bang: the body has"* ]]
}

@test "findings: a footer in a branch commit message without the title's bang is refused (#1571)" {
  # Under a commit-messages squash setting the branch's messages become the squash body.
  run pr_body_marker_findings 'feat(canary): make the input required (#1)' 'a clean body' \
    $'feat: tidy\n\nfix: make the input required\n\nBREAKING CHANGE: the input is required'
  [ "$status" -eq 1 ]
  [[ "$output" == "breaking-footer-without-bang: a commit message has"* ]]
  run pr_body_marker_findings 'feat(canary)!: make the input required (#1)' 'a clean body' \
    $'fix: x\n\nBREAKING CHANGE: y'
  [ "$status" -eq 0 ]
}

@test "findings: a skip-CI marker in a branch commit message is refused (#1571)" {
  run pr_body_marker_findings 'docs: x (#1)' 'a clean body' $'docs: wip [ci skip]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"skip-ci-marker: '[ci skip]'"* ]]
}

@test "findings: a footer with the title's bang passes (#1571)" {
  run pr_body_marker_findings 'feat(canary)!: make the input required (#1)' $'## Why\n\nx\n\nBREAKING CHANGE: the input is required'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "findings: each skip-CI marker in the body is refused, in any case (#1571)" {
  local m
  for m in '[skip ci]' '[ci skip]' '[no ci]' '[skip actions]' '[actions skip]' '[Skip CI]'; do
    run pr_body_marker_findings 'docs: fix a typo (#1)' $'## Why\n\nA typo '"$m"$' fixed.'
    [ "$status" -eq 1 ]
    [[ "$output" == *"skip-ci-marker: '$m'"* ]]
  done
}

@test "findings: a skip-CI marker in the title or a skip-checks trailer is refused (#1571)" {
  run pr_body_marker_findings 'docs: fix a typo [skip ci] (#1)' 'x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"skip-ci-marker: '[skip ci]'"* ]]
  run pr_body_marker_findings 'docs: fix a typo (#1)' $'x\n\nskip-checks: true'
  [ "$status" -eq 1 ]
  [[ "$output" == *"skip-ci-marker: 'skip-checks: true'"* ]]
}

@test "findings: both problems are reported together (#1571)" {
  run pr_body_marker_findings 'feat: x (#1)' $'BREAKING CHANGE: y\n[no ci]'
  [ "$status" -eq 1 ]
  [ "$(grep -c . <<< "$output")" -eq 2 ]
}

@test "findings: a plain body with the words skip and ci apart passes (#1571)" {
  run pr_body_marker_findings 'ci: skip the slow job on docs-only changes (#1)' $'## Why\n\nWe skip CI work for docs. Not a marker: skip ci, ci-skip, [skip-ci].'
  [ "$status" -eq 0 ]
}

@test "a body quoting the guidance mid-line, inside a comment, passes (#1571)" {
  local body
  body=$'<!--\nBreaking change? Put `!` after the scope in the title.\nA `BREAKING CHANGE:` line is not read.\n-->\n\n## Why\n\n## What changed\n'
  run pr_body_marker_findings 'docs: x (#1)' "$body"
  [ "$status" -eq 0 ]
}

@test "CLI: reads the title and body from the environment and fails with ::error:: lines (#1571)" {
  run env PR_TITLE='feat: x (#1)' PR_BODY=$'BREAKING CHANGE: y' bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::breaking-footer-without-bang:"* ]]
  run env PR_TITLE='feat: x (#1)' PR_BODY='a clean body' bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr-body-markers: clean"* ]]
}

@test "CLI: reads the commit messages from PR_COMMITS_FILE (#1571)" {
  local f="$BATS_TEST_TMPDIR/commits.txt"
  printf 'fix: x\n\nBREAKING CHANGE: y\n' > "$f"
  run env PR_TITLE='fix: x (#1)' PR_BODY='clean' PR_COMMITS_FILE="$f" bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::breaking-footer-without-bang: a commit message has"* ]]
  run env PR_TITLE='fix: x (#1)' PR_BODY='clean' PR_COMMITS_FILE="$BATS_TEST_TMPDIR/missing" bash "$CHECK"
  [ "$status" -eq 2 ]
}

@test "CLI: an empty or missing body passes (#1571)" {
  run env -u PR_BODY PR_TITLE='docs: x (#1)' bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "CLI: body text is never evaluated by the shell (#1571)" {
  local marker="$BATS_TEST_TMPDIR/pwned"
  run env PR_TITLE='docs: x (#1)' PR_BODY="\$(touch $marker) \`touch $marker\`" bash "$CHECK"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}
