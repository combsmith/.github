#!/usr/bin/env bats
# Unit tests for the standards channel staleness alarm (issue #1173): the pure
# decision core scripts/lib/standards-staleness.sh, and the gh glue
# scripts/standards-staleness.sh with gh stubbed on PATH.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/standards-staleness.sh"
ORCH="$SCRIPT_DIR/scripts/standards-staleness.sh"

CH_SHA="1111111111111111111111111111111111111111"
BR_SHA="2222222222222222222222222222222222222222"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── pure core ──────────────────────────────────────────────────────────────────
@test "ss_standards_files: keeps only paths under standards/" {
  run bash -c "source '$LIB'; printf '%s\n' standards/a.md scripts/x.sh .github/workflows/standards-y.yml standards/workflows/ci.yml | ss_standards_files"
  [ "$output" = "$(printf 'standards/a.md\nstandards/workflows/ci.yml')" ]
}
@test "ss_workflow_files: keeps only paths under standards/workflows/" {
  run bash -c "source '$LIB'; printf '%s\n' standards/a.md standards/workflows/ci.yml standards/workflows-notes.md | ss_workflow_files"
  [ "$output" = "standards/workflows/ci.yml" ]
}
@test "ss_age_days: whole days, floored" {
  [ "$(ss_age_days 1000000 $((1000000 - 86400 * 3 - 5)))" = "3" ]
  [ "$(ss_age_days 1000000 $((1000000 - 86399)))" = "0" ]
}
@test "ss_age_days: a future timestamp is 0 days, never negative" {
  [ "$(ss_age_days 1000 2000)" = "0" ]
}
@test "ss_age_days: a non-numeric input fails instead of guessing" {
  run ss_age_days 1000 ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
@test "ss_decision: no differing standards file is FRESH" {
  [ "$(ss_decision 0 0 0 7)" = "FRESH" ]
  [ "$(ss_decision 0 0 400 7)" = "FRESH" ]
}
@test "ss_decision: a differing workflow template is STALE at once, whatever its age" {
  [ "$(ss_decision 3 1 0 7)" = "STALE workflows" ]
}
@test "ss_decision: a non-template difference older than the limit is STALE" {
  [ "$(ss_decision 2 0 8 7)" = "STALE age" ]
}
@test "ss_decision: a non-template difference at the limit is still PENDING" {
  [ "$(ss_decision 2 0 7 7)" = "PENDING" ]
  [ "$(ss_decision 2 0 0 7)" = "PENDING" ]
}
@test "ss_decision: inputs that are not numbers are UNKNOWN, never FRESH" {
  [ "$(ss_decision "" 0 0 7)" = "UNKNOWN" ]
  [ "$(ss_decision 2 0 "" 7)" = "UNKNOWN" ]
  [ "$(ss_decision 2 0 3 seven)" = "UNKNOWN" ]
}
@test "ss_issue_body: carries the marker, both commits, the reason and every file" {
  run bash -c "source '$LIB'; printf 'modified\tstandards/workflows/ci.yml\nadded\tstandards/new.md\n' | ss_issue_body standards/v1-stable $CH_SHA main $BR_SHA 14 'STALE workflows' 3 7 0 0"
  [ "$status" -eq 0 ]
  [[ "$output" == "<!-- standards-channel-staleness channel=standards/v1-stable -->"* ]]
  [[ "$output" == *"111111111111"* && "$output" == *"222222222222"* ]]
  [[ "$output" == *"by 14 commit(s). 2 file(s)"* ]]
  [[ "$output" == *'| `standards/workflows/ci.yml` | modified |'* ]]
  [[ "$output" == *'| `standards/new.md` | added |'* ]]
  [[ "$output" == *"no canary stage"* ]]
  [[ "$output" == *"cut-standards-release.sh verify"* ]]
}
@test "ss_issue_body: an age that is only an upper bound is stated as one" {
  run bash -c "source '$LIB'; printf 'modified\tstandards/a.md\n' | ss_issue_body standards/v1-stable $CH_SHA main $BR_SHA 2 'STALE age' 9 7 1 0"
  [[ "$output" == *"is at most 9 days old. The limit is 7 days."* ]]
}
@test "ss_issue_body: a truncated file list says it may be incomplete" {
  run bash -c "source '$LIB'; printf 'modified\tstandards/a.md\n' | ss_issue_body standards/v1-stable $CH_SHA main $BR_SHA 2 'STALE age' 9 7 0 1"
  [[ "$output" == *"may be incomplete"* ]]
}

# ── gh glue, with gh stubbed ───────────────────────────────────────────────────
# The stub answers each read from a fixture file and logs every issue write.
#   $STUB/compare.json   the compare API response (absent → the call fails)
#   $STUB/commits.tsv    "<sha>\t<iso date>" rows for the standards/ commit list
#   $STUB/issues.json    the open-issue list
#   $STUB/refs.txt       the standards/* tag refs
#   $STUB/writes.log     one line per `gh issue create|edit|close`
#   $STUB/body.md        the body file of the last create/edit
_stub() {
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  export STUB
  printf 'refs/tags/standards/v1-stable\nrefs/tags/standards/v1.0.0\nrefs/tags/standards/v1.1.0\n' > "$STUB/refs.txt"
  echo '[]' > "$STUB/issues.json"
  : > "$STUB/commits.tsv"
  : > "$STUB/writes.log"
  cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
args="$*"
case "$1 $2" in
  "issue list") cat "$STUB/issues.json"; exit 0 ;;
  "issue create"|"issue edit"|"issue close")
    echo "$args" >> "$STUB/writes.log"
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && cp "$2" "$STUB/body.md"
      shift
    done
    exit 0 ;;
esac
case "$args" in
  *"matching-refs/tags/standards/v"*) cat "$STUB/refs.txt" ;;
  *"/compare/"*) [ -f "$STUB/compare.json" ] || { echo "gh: HTTP 502" >&2; exit 1; }; cat "$STUB/compare.json" ;;
  *"application/vnd.github.sha"*) printf '2222222222222222222222222222222222222222' ;;
  *"path=standards"*) cat "$STUB/commits.tsv" ;;
  *"--jq .default_branch"*) echo main ;;
  *) echo "unexpected gh call: $args" >&2; exit 97 ;;
esac
GH
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
  export SS_REPO="petry-projects/.github"
  unset SS_CHANNEL SS_BRANCH DRY_RUN STANDARDS_STALENESS_MAX_DAYS GITHUB_STEP_SUMMARY
}

# _iso_days_ago <n> — an ISO-8601 UTC timestamp n days before now.
_iso_days_ago() { jq -rn --argjson n "$1" 'now - ($n * 86400) | todate'; }

# _compare <channel-commit age in days> <file>... — write the compare fixture.
_compare() {
  local age="$1"; shift
  local files
  files="$(printf '%s\n' "$@" | jq -R 'select(length > 0) | {filename: ., status: "modified"}' | jq -s .)"
  jq -n --arg sha "$CH_SHA" --arg d "$(_iso_days_ago "$age")" --argjson files "$files" \
    '{status: "ahead", ahead_by: 5, base_commit: {sha: $sha, commit: {committer: {date: $d}}}, files: $files}' \
    > "$STUB/compare.json"
}

@test "glue: only non-standards files differ → FRESH, nothing written" {
  _stub
  _compare 30 scripts/x.sh .github/workflows/ci.yml
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: FRESH"* ]]
  [ ! -s "$STUB/writes.log" ]
}

@test "glue: a differing workflow template opens the alarm issue listing the files" {
  _stub
  _compare 1 standards/workflows/agent-shield.yml standards/ci-standards.md scripts/x.sh
  printf 'cccc\t%s\n' "$(_iso_days_ago 0)" > "$STUB/commits.tsv"
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: STALE workflows"* ]]
  run cat "$STUB/writes.log"
  [[ "$output" == "issue create --repo petry-projects/.github --title Standards channel standards/v1-stable is behind main — promote it --body-file "* ]]
  [ "$(wc -l < "$STUB/writes.log")" -eq 1 ]
  run cat "$STUB/body.md"
  [[ "$output" == *"standards/workflows/agent-shield.yml"* ]]
  [[ "$output" == *"standards/ci-standards.md"* ]]
  [[ "$output" != *"scripts/x.sh"* ]]
}

@test "glue: a non-template difference older than the limit opens the alarm" {
  _stub
  _compare 20 standards/ci-standards.md
  printf 'cccc\t%s\ndddd\t%s\n' "$(_iso_days_ago 2)" "$(_iso_days_ago 9)" > "$STUB/commits.tsv"
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"oldest:   9 day(s) — limit 7"* ]]
  [[ "$output" == *"decision: STALE age"* ]]
  grep -q '^issue create ' "$STUB/writes.log"
}

@test "glue: a recent non-template difference is PENDING, nothing written" {
  _stub
  _compare 20 standards/ci-standards.md
  printf 'cccc\t%s\n' "$(_iso_days_ago 2)" > "$STUB/commits.tsv"
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision: PENDING"* ]]
  [ ! -s "$STUB/writes.log" ]
}

@test "glue: STANDARDS_STALENESS_MAX_DAYS moves the limit" {
  _stub
  _compare 20 standards/ci-standards.md
  printf 'cccc\t%s\n' "$(_iso_days_ago 2)" > "$STUB/commits.tsv"
  STANDARDS_STALENESS_MAX_DAYS=1 run bash "$ORCH"
  [[ "$output" == *"decision: STALE age"* ]]
}

@test "glue: the channel commit itself is not counted as an unpublished change" {
  _stub
  _compare 20 standards/ci-standards.md
  # The since= filter is inclusive, so the list can include the channel commit.
  printf 'cccc\t%s\n%s\t%s\n' "$(_iso_days_ago 1)" "$CH_SHA" "$(_iso_days_ago 20)" > "$STUB/commits.tsv"
  run bash "$ORCH"
  [[ "$output" == *"oldest:   1 day(s) — limit 7"* ]]
  [[ "$output" == *"decision: PENDING"* ]]
}

@test "glue: no dated commit found → age falls back to the channel commit, stated as an upper bound" {
  _stub
  _compare 12 standards/ci-standards.md
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"oldest:   12 day(s) (upper bound) — limit 7"* ]]
  [[ "$output" == *"decision: STALE age"* ]]
  grep -q "at most 12 days old" "$STUB/body.md"
}

@test "glue: an open alarm issue is updated in place, not duplicated" {
  _stub
  _compare 1 standards/workflows/agent-shield.yml
  echo '[{"number":41,"body":"unrelated"},{"number":77,"body":"<!-- standards-channel-staleness channel=standards/v1-stable -->\n\nold"}]' > "$STUB/issues.json"
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated alarm issue #77"* ]]
  grep -q '^issue edit 77 ' "$STUB/writes.log"
  ! grep -q '^issue create ' "$STUB/writes.log"
}

@test "glue: another channel's alarm issue is not adopted" {
  _stub
  _compare 1 standards/workflows/agent-shield.yml
  echo '[{"number":77,"body":"<!-- standards-channel-staleness channel=standards/v2-stable -->"}]' > "$STUB/issues.json"
  run bash "$ORCH"
  grep -q '^issue create ' "$STUB/writes.log"
  ! grep -q '^issue edit ' "$STUB/writes.log"
}

@test "glue: once the channel catches up the open alarm issue is closed" {
  _stub
  _compare 1 scripts/x.sh
  echo '[{"number":77,"body":"<!-- standards-channel-staleness channel=standards/v1-stable -->"}]' > "$STUB/issues.json"
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed alarm issue #77"* ]]
  grep -q '^issue close 77 ' "$STUB/writes.log"
}

@test "glue: DRY_RUN=true prints the issue and writes nothing" {
  _stub
  _compare 1 standards/workflows/agent-shield.yml
  DRY_RUN=true run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would open an issue"* ]]
  [[ "$output" == *"standards/workflows/agent-shield.yml"* ]]
  [ ! -s "$STUB/writes.log" ]
}

@test "glue: a failed compare fails the run — never reported as fresh" {
  _stub
  rm -f "$STUB/compare.json"
  run bash "$ORCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not compare standards/v1-stable with main"* ]]
  [[ "$output" != *"decision:"* ]]
  [ ! -s "$STUB/writes.log" ]
}

@test "glue: a compare response without the expected fields fails the run" {
  _stub
  echo '{"message":"Not Found"}' > "$STUB/compare.json"
  run bash "$ORCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"without the expected fields"* ]]
  [ ! -s "$STUB/writes.log" ]
}

@test "glue: no published release → a notice, exit 0, nothing compared" {
  _stub
  printf 'refs/tags/standards/v1-stable\n' > "$STUB/refs.txt"
  rm -f "$STUB/compare.json"
  run bash "$ORCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no standards/vX.Y.Z release is published"* ]]
}

@test "glue: the channel checked is the one of the highest published release" {
  _stub
  printf 'refs/tags/standards/v1.9.0\nrefs/tags/standards/v2.0.1\nrefs/tags/standards/v2-stable\n' > "$STUB/refs.txt"
  _compare 1 scripts/x.sh
  run bash "$ORCH"
  [[ "$output" == *"channel:  standards/v2-stable"* ]]
}

@test "glue: a non-numeric day limit is refused" {
  _stub
  _compare 1 scripts/x.sh
  STANDARDS_STALENESS_MAX_DAYS=soon run bash "$ORCH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a whole number of days"* ]]
}
