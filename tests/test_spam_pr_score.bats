#!/usr/bin/env bats
# Unit tests for scripts/spam-pr-score.sh — the deterministic, metadata-only
# spam-PR scorer (epic #1200, story #1203; signal table per discussion #1198).
#
# The pure core (sps_score) maps a PR "facts" JSON document plus the config
# standards/spam-pr-guard.json to key=value verdict lines, with no network, no
# checkout and no LLM. The gh glue (--repo/--pr) is covered by a stubbed `gh`.
#
# The three fixtures under tests/fixtures/spam-pr-guard/ are the FROZEN
# regression baseline Phase 5 tunes against:
#   - pr-1976-style.json       -> high (raw 10), auto-close eligible
#   - legit-first-time.json    -> raw 1 (the counterfactual — asserted on the
#                                 raw points total, never a mutable threshold)
#   - security-sensitive.json  -> escalate, never auto-close eligible
#
# Pattern follows tests/test_safety_checks.bats.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/spam-pr-score.sh"
  CONFIG="$REPO_ROOT/standards/spam-pr-guard.json"
  FIX="$REPO_ROOT/tests/fixtures/spam-pr-guard"
  TMP="$BATS_TEST_TMPDIR"
}

# variant <fixture> <jq-filter> — write a modified copy of a fixture, echo its path.
variant() {
  local out
  out="$(mktemp "$TMP/facts.XXXXXX.json")"
  jq "$2" "$FIX/$1" >"$out"
  printf '%s\n' "$out"
}

# field <name> — extract one key=value line's value from $output.
field() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p"
}

# --- frozen fixtures (AC7) --------------------------------------------------

@test "fixture: #1976-style PR scores high and is auto-close eligible" {
  run "$SCRIPT" --facts "$FIX/pr-1976-style.json"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "true" ]
  [ "$(field raw_score)" = "10" ]
  [ "$(field level)" = "high" ]
  [ "$(field escalate)" = "false" ]
  [ "$(field auto_close_eligible)" = "true" ]
  [ "$(field signals)" = "empty_template,bare_title,small_doc_diff_no_issue,typo_introduced,fork_default_branch,new_account_no_activity" ]
}

@test "fixture: legitimate first-time PR scores a fixed raw 1 (counterfactual)" {
  # Asserted on the RAW points total, not on a level, so later threshold tuning
  # cannot turn this baseline red.
  run "$SCRIPT" --facts "$FIX/legit-first-time.json"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "true" ]
  [ "$(field raw_score)" = "1" ]
  [ "$(field signals)" = "fork_default_branch" ]
  [ "$(field escalate)" = "false" ]
  [ "$(field auto_close_eligible)" = "false" ]
}

@test "fixture: security-sensitive PR escalates and is never auto-close eligible" {
  run "$SCRIPT" --facts "$FIX/security-sensitive.json"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "true" ]
  [ "$(field raw_score)" = "5" ]
  [ "$(field escalate)" = "true" ]
  [ "$(field escalate_reason)" = "security-sensitive-path:.github/workflows/ci.yml" ]
  [ "$(field auto_close_eligible)" = "false" ]
}

@test "security-sensitive escalation wins even when the score is high" {
  f="$(variant pr-1976-style.json '.files += [{path: "scripts/install.sh", additions: 1, deletions: 0, patch: "+x"}]')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field level)" = "high" ]
  [ "$(field escalate)" = "true" ]
  [ "$(field auto_close_eligible)" = "false" ]
}

@test "secrets path (.env) escalates" {
  f="$(variant legit-first-time.json '.files = [{path: "config/.env.production", additions: 1, deletions: 0, patch: "+A=1"}]')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field escalate)" = "true" ]
}

# --- determinism (AC1) ----------------------------------------------------------

@test "identical inputs always yield identical output" {
  run "$SCRIPT" --facts "$FIX/pr-1976-style.json"
  first="$output"
  run "$SCRIPT" --facts "$FIX/pr-1976-style.json"
  [ "$output" = "$first" ]
}

@test "facts can be piped on stdin" {
  run bash -c "'$SCRIPT' --facts - < '$FIX/pr-1976-style.json'"
  [ "$status" -eq 0 ]
  [ "$(field raw_score)" = "10" ]
}

# --- gate (AC2) -------------------------------------------------------------

@test "gate: MEMBER scores 0 and is never flagged, even on a security path" {
  f="$(variant security-sensitive.json '.author_association = "MEMBER"')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "false" ]
  [ "$(field exempt_reason)" = "association:MEMBER" ]
  [ "$(field raw_score)" = "0" ]
  [ "$(field level)" = "low" ]
  [ "$(field escalate)" = "false" ]
  [ "$(field auto_close_eligible)" = "false" ]
}

@test "gate: COLLABORATOR and OWNER score 0" {
  for a in COLLABORATOR OWNER; do
    f="$(variant pr-1976-style.json ".author_association = \"$a\"")"
    run "$SCRIPT" --facts "$f"
    [ "$status" -eq 0 ]
    [ "$(field scored)" = "false" ]
    [ "$(field raw_score)" = "0" ]
  done
}

@test "gate: a bot scores 0 regardless of association" {
  f="$(variant pr-1976-style.json '.author_type = "Bot" | .author_association = "NONE"')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "false" ]
  [ "$(field exempt_reason)" = "bot" ]
  [ "$(field raw_score)" = "0" ]
}

@test "gate: exempt authors need only the gate facts (no fail-closed on the rest)" {
  f="$(variant pr-1976-style.json '.author_association = "MEMBER" | del(.files, .org_open_prs_24h)')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "false" ]
}

@test "gate: NONE and FIRST_TIMER are scored" {
  for a in NONE FIRST_TIMER; do
    f="$(variant pr-1976-style.json ".author_association = \"$a\"")"
    run "$SCRIPT" --facts "$f"
    [ "$status" -eq 0 ]
    [ "$(field scored)" = "true" ]
  done
}

@test "gate: a CONTRIBUTOR from a fork is scored; from a same-repo branch it is not" {
  f="$(variant pr-1976-style.json '.author_association = "CONTRIBUTOR"')"
  run "$SCRIPT" --facts "$f"
  [ "$(field scored)" = "true" ]
  f="$(variant pr-1976-style.json '.author_association = "CONTRIBUTOR" | .is_fork = false')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "false" ]
  [ "$(field exempt_reason)" = "association:CONTRIBUTOR" ]
}

# --- individual signals -------------------------------------------------------

@test "signal: burst fires above N (config burst_limit) and not at N" {
  f="$(variant legit-first-time.json '.org_open_prs_24h = 4')"
  run "$SCRIPT" --facts "$f"
  [ "$(field raw_score)" = "4" ]
  [[ "$(field signals)" == *burst* ]]
  f="$(variant legit-first-time.json '.org_open_prs_24h = 3')"
  run "$SCRIPT" --facts "$f"
  [ "$(field raw_score)" = "1" ]
}

@test "signal: empty template reuses sc_description_missing (empty body -> fires)" {
  f="$(variant legit-first-time.json '.body = ""')"
  run "$SCRIPT" --facts "$f"
  [ "$(field raw_score)" = "4" ]
  [[ "$(field signals)" == *empty_template* ]]
}

@test "signal: a null body is an empty body, not an unreadable one" {
  f="$(variant legit-first-time.json '.body = null')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [[ "$(field signals)" == *empty_template* ]]
}

@test "signal: a descriptive title does not fire bare_title" {
  f="$(variant pr-1976-style.json '.title = "Clarify the install steps for Windows users"')"
  run "$SCRIPT" --facts "$f"
  [[ "$(field signals)" != *bare_title* ]]
  [ "$(field raw_score)" = "8" ]
}

@test "signal: a linked issue suppresses the small docs diff signal" {
  f="$(variant pr-1976-style.json '.body = "Fixes #12\n" + .body')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field raw_score)" -ge 0 ]
  [[ "$(field signals)" != *small_doc_diff_no_issue* ]]
}

@test "signal: an issue reference inside an HTML comment does not count as linked" {
  f="$(variant pr-1976-style.json '.body = "<!-- see #12 -->\n" + .body')"
  run "$SCRIPT" --facts "$f"
  [[ "$(field signals)" == *small_doc_diff_no_issue* ]]
}

@test "signal: a larger docs diff does not fire small_doc_diff_no_issue" {
  f="$(variant pr-1976-style.json '.files[0].additions = 4')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field raw_score)" -ge 0 ]
  [[ "$(field signals)" != *small_doc_diff_no_issue* ]]
}

@test "signal: a typo already present in the removed line is not introduced" {
  f="$(variant pr-1976-style.json '.files[0].patch = "-Teh old line\n+Teh new line"')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field raw_score)" -ge 0 ]
  [[ "$(field signals)" != *typo_introduced* ]]
}

@test "signal: a feature branch on the fork does not fire fork_default_branch" {
  f="$(variant legit-first-time.json '.head_ref = "fix-pagination"')"
  run "$SCRIPT" --facts "$f"
  [ "$(field raw_score)" = "0" ]
  [ "$(field level)" = "low" ]
}

@test "signal: a new account WITH activity does not fire new_account_no_activity" {
  f="$(variant pr-1976-style.json '.author_followers = 5')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 0 ]
  [ "$(field raw_score)" -ge 0 ]
  [[ "$(field signals)" != *new_account_no_activity* ]]
}

@test "level: raw score at the medium threshold maps to medium" {
  # empty template (3) + fork default branch (1) = 4 = medium default.
  f="$(variant legit-first-time.json '.body = ""')"
  run "$SCRIPT" --facts "$f"
  [ "$(field level)" = "medium" ]
  [ "$(field auto_close_eligible)" = "false" ]
}

# --- config-driven (AC4) ------------------------------------------------------

@test "config: weights and thresholds are read from the config file, not hardcoded" {
  cfg="$TMP/config.json"
  jq '.weights.fork_default_branch = 7 | .thresholds.high = 7' "$CONFIG" >"$cfg"
  run "$SCRIPT" --facts "$FIX/legit-first-time.json" --config "$cfg"
  [ "$status" -eq 0 ]
  [ "$(field raw_score)" = "7" ]
  [ "$(field level)" = "high" ]
}

@test "config: the security path list is read from config" {
  cfg="$TMP/config.json"
  jq '.security_sensitive_paths = ["src/*"]' "$CONFIG" >"$cfg"
  run "$SCRIPT" --facts "$FIX/legit-first-time.json" --config "$cfg"
  [ "$(field escalate)" = "true" ]
}

@test "config: the shipped defaults are medium>=4, high>=6, N=3" {
  [ "$(jq '.thresholds.medium' "$CONFIG")" = "4" ]
  [ "$(jq '.thresholds.high' "$CONFIG")" = "6" ]
  [ "$(jq '.signals.burst_limit' "$CONFIG")" = "3" ]
}

# --- fail-closed (AC5) --------------------------------------------------------
# Fail-closed is exit 2 specifically (not just non-zero), so a crash or a
# missing script cannot masquerade as a deliberate escalation.

@test "fail-closed: a missing required fact exits non-zero with no verdict" {
  f="$(variant pr-1976-style.json 'del(.org_open_prs_24h)')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *org_open_prs_24h* ]]
  [[ "$output" != *level=* ]]
}

@test "fail-closed: a wrongly typed fact exits non-zero" {
  f="$(variant pr-1976-style.json '.author_followers = "many"')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 2 ]
}

@test "fail-closed: an empty file list exits non-zero" {
  f="$(variant pr-1976-style.json '.files = []')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 2 ]
}

@test "fail-closed: an unparseable timestamp exits non-zero" {
  f="$(variant pr-1976-style.json '.author_created_at = "yesterday"')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 2 ]
}

@test "fail-closed: a missing gate fact (association) exits non-zero" {
  f="$(variant pr-1976-style.json 'del(.author_association)')"
  run "$SCRIPT" --facts "$f"
  [ "$status" -eq 2 ]
}

@test "fail-closed: malformed facts JSON exits non-zero" {
  printf '{not json' >"$TMP/bad.json"
  run "$SCRIPT" --facts "$TMP/bad.json"
  [ "$status" -eq 2 ]
}

@test "fail-closed: a missing config exits non-zero" {
  run "$SCRIPT" --facts "$FIX/pr-1976-style.json" --config "$TMP/nope.json"
  [ "$status" -eq 2 ]
}

@test "fail-closed: a config missing a weight exits non-zero" {
  cfg="$TMP/config.json"
  jq 'del(.weights.burst)' "$CONFIG" >"$cfg"
  run "$SCRIPT" --facts "$FIX/pr-1976-style.json" --config "$cfg"
  [ "$status" -eq 2 ]
}

@test "fail-closed: a failing sc_description_missing exits non-zero" {
  run bash -c "source '$SCRIPT'; sc_description_missing() { return 1; }; sps_score '$FIX/pr-1976-style.json' '$CONFIG'"
  [ "$status" -eq 2 ]
}

@test "sourced under errexit: sps_score scores a legit fixture without aborting" {
  run bash -ec "source '$SCRIPT'; sps_score '$FIX/legit-first-time.json' '$CONFIG'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scored="* ]]
}

@test "usage: no mode argument exits non-zero" {
  run "$SCRIPT"
  [ "$status" -eq 64 ]
}

# --- gh glue (stubbed gh, no network) ---------------------------------------

# make_gh_stub <search_total> [fail_on] — a fake `gh` on PATH serving canned
# API responses; `fail_on` makes a matching endpoint exit non-zero.
make_gh_stub() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
args="\$*"
if [ -n "${2:-}" ] && [[ "\$args" == *"${2:-}"* ]]; then echo "stub failure" >&2; exit 1; fi
case "\$args" in
  *search/issues*) echo '{"total_count": $1, "incomplete_results": false}' ;;
  *pulls/7/files*) echo '[{"filename":"README.md","additions":1,"deletions":1,"patch":"-The x\n+Teh x"}]' ;;
  *pulls/7*) echo '{"changed_files":1,"title":"Update README.md","body":null,"author_association":"NONE","user":{"login":"drive-by","type":"User"},"head":{"ref":"main","repo":{"full_name":"drive-by/repo","default_branch":"main"}},"base":{"repo":{"full_name":"acme/repo"}}}' ;;
  *users/drive-by*) echo '{"created_at":"2026-11-20T00:00:00Z","followers":0,"public_repos":1}' ;;
  *) echo "unexpected gh call: \$args" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
}

@test "glue: gathers facts via gh and scores them" {
  make_gh_stub 5
  run env PATH="$TMP/bin:$PATH" SPS_NOW="2026-11-22T12:00:00Z" "$SCRIPT" --repo acme/repo --pr 7
  [ "$status" -eq 0 ]
  [ "$(field scored)" = "true" ]
  # empty(3)+bare(2)+small doc(2)+typo(1)+fork default(1)+new account(1)+burst(3)
  [ "$(field raw_score)" = "13" ]
  [ "$(field level)" = "high" ]
}

@test "glue: a failing gh call fails closed" {
  make_gh_stub 0 search/issues
  run env PATH="$TMP/bin:$PATH" SPS_NOW="2026-11-22T12:00:00Z" "$SCRIPT" --repo acme/repo --pr 7
  [ "$status" -eq 2 ]
  [[ "$output" != *level=* ]]
}

@test "fail-closed: an invalid configured regular expression exits non-zero" {
  cfg="$TMP/config.json"
  jq '.linked_issue_patterns = ["["]' "$CONFIG" >"$cfg"
  run "$SCRIPT" --facts "$FIX/pr-1976-style.json" --config "$cfg"
  [ "$status" -eq 2 ]
  [[ "$output" != *level=* ]]
}

@test "glue: a rename out of a security-sensitive path escalates" {
  make_gh_stub 0
  sed -i 's|"filename":"README.md",|"filename":"README.md","previous_filename":".github/workflows/ci.yml",|' "$TMP/bin/gh"
  run env PATH="$TMP/bin:$PATH" SPS_NOW="2026-11-22T12:00:00Z" "$SCRIPT" --repo acme/repo --pr 7
  [ "$status" -eq 0 ]
  [ "$(field escalate)" = "true" ]
  [ "$(field auto_close_eligible)" = "false" ]
}

@test "glue: an incomplete file inventory fails closed" {
  make_gh_stub 0
  sed -i 's|"changed_files":1|"changed_files":2|' "$TMP/bin/gh"
  run env PATH="$TMP/bin:$PATH" SPS_NOW="2026-11-22T12:00:00Z" "$SCRIPT" --repo acme/repo --pr 7
  [ "$status" -eq 2 ]
}

@test "glue: a deleted head repo is not exempted for a CONTRIBUTOR" {
  make_gh_stub 0
  sed -i 's|"author_association":"NONE"|"author_association":"CONTRIBUTOR"|; s|"repo":{"full_name":"drive-by/repo","default_branch":"main"}|"repo":null|' "$TMP/bin/gh"
  run env PATH="$TMP/bin:$PATH" SPS_NOW="2026-11-22T12:00:00Z" "$SCRIPT" --repo acme/repo --pr 7
  [ "$status" -eq 2 ]
}

@test "glue: a very large patch does not hit the argument-size limit" {
  make_gh_stub 0
  head -c 200000 /dev/zero | tr '\0' 'a' \
    | jq -Rs '[{filename:"README.md",additions:1,deletions:0,patch:("+"+.)}]' >"$TMP/files.json"
  sed -i "s|^  \*pulls/7/files\*).*|  *pulls/7/files*) cat '$TMP/files.json' ;;|" "$TMP/bin/gh"
  run env PATH="$TMP/bin:$PATH" SPS_NOW="2026-11-22T12:00:00Z" "$SCRIPT" --repo acme/repo --pr 7
  [ "$status" -eq 0 ]
}

# --- lint (AC8) ---------------------------------------------------------------

@test "spam-pr-score.sh passes shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck is required for this test" >&2
    return 1
  fi
  cd "$REPO_ROOT"
  run shellcheck -x "$SCRIPT"
  [ "$status" -eq 0 ]
}
