#!/usr/bin/env bats
# Tests for classify-initiative.sh — the deterministic Initiative/Theme
# back-fill classifier:
#   - pure classification (signature build, rule match, taxonomy roll-up)
#   - the gate-label strip that stops the universal `dev-lead` label from
#     making every item look like the "dev-lead agent" initiative
#   - the sweep: resolve fields → page items → set values (DRY_RUN + apply),
#     skipping already-associated items and leaving unmatched ones blank.
#
# Classification cases run against the REAL rules/taxonomy TSVs, so they also
# guard those data files against regressions.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export PROJECT_ID="PVT_test_project"
  export PROJECT_URL="https://example.invalid/projects/1"
  export GH_TOKEN="t_test"
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/classify-initiative.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

# One-page items response. Each arg is a compact JSON node object.
write_items_page() {
  local out_path="$1"; shift
  local nodes='[]'
  local n
  for n in "$@"; do
    nodes=$(jq --argjson node "$n" '. + [$node]' <<<"$nodes")
  done
  jq --argjson nodes "$nodes" \
     '{data:{node:{items:{pageInfo:{hasNextPage:false,endCursor:""},nodes:$nodes}}}}' \
     <<<"{}" >"$out_path"
}

# Field-schema response used by resolve_fields.
write_fields_schema() {
  local out_path="$1"
  cat >"$out_path" <<'JSON'
{"data":{"node":{
  "initiative":{"id":"F_INIT","options":[
    {"id":"o_orgstd","name":"Org Standards"},
    {"id":"o_auto","name":"Auto-rebase"},
    {"id":"o_devlead","name":"dev-lead agent"}
  ]},
  "theme":{"id":"F_THEME","options":[
    {"id":"t_fleet","name":"Fleet Operations"},
    {"id":"t_comp","name":"Compliance"},
    {"id":"t_agentic","name":"Agentic Framework"}
  ]}
}}}
JSON
}

gh_script_line() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

assert_invocation_count() {
  local expected="$1" actual=0
  [ -f "${GH_STUB_LOG}" ] && actual=$(wc -l <"${GH_STUB_LOG}" | tr -d ' ')
  [ "$actual" -eq "$expected" ] || {
    printf 'expected %d gh invocations, got %d\n' "$expected" "$actual" >&2
    [ -f "${GH_STUB_LOG}" ] && cat "${GH_STUB_LOG}" >&2
    return 1
  }
}

assert_log_contains() {
  local blob; blob=$(sed 's/\\//g' "${GH_STUB_LOG}")
  for needle in "$@"; do
    [[ "$blob" == *"${needle}"* ]] || {
      printf 'expected gh log to contain %q\nlog: %s\n' "$needle" "$blob" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Arg validation
# ---------------------------------------------------------------------------

@test "normalize_signature: rejects wrong arg count" {
  run normalize_signature "t" "[]"
  [ "$status" -eq 64 ]
}

@test "classify_by_rules: rejects wrong arg count" {
  run classify_by_rules
  [ "$status" -eq 64 ]
}

@test "theme_for: rejects wrong arg count" {
  run theme_for a b
  [ "$status" -eq 64 ]
}

@test "decide_for_signature: rejects wrong arg count" {
  run decide_for_signature
  [ "$status" -eq 64 ]
}

# ---------------------------------------------------------------------------
# normalize_signature — lowercasing + gate-label strip
# ---------------------------------------------------------------------------

@test "normalize_signature: lowercases and joins title | labels | repo" {
  run normalize_signature "Fix The Thing" '[{"name":"auto-rebase"}]' "combsmith/.github"
  [ "$status" -eq 0 ]
  [[ "$output" == "fix the thing | auto-rebase | combsmith/.github" ]]
}

@test "normalize_signature: strips the dev-lead gate label but keeps real labels" {
  run normalize_signature "some title" '[{"name":"dev-lead"},{"name":"auto-rebase"}]' "o/r"
  [ "$status" -eq 0 ]
  [[ "$output" != *"dev-lead"* ]]
  [[ "$output" == *"auto-rebase"* ]]
}

@test "normalize_signature: strips dev-lead:* and initiative:* routing variants" {
  # These colon-variants contain dev-lead/initiative and would otherwise drive
  # a spurious dev-lead-agent / Initiatives-Project match.
  run normalize_signature "some title" '[{"name":"dev-lead:needs-human"},{"name":"initiative:auto"},{"name":"scorecard"}]' "o/r"
  [ "$status" -eq 0 ]
  [[ "$output" != *"dev-lead"* ]]
  [[ "$output" != *"initiative"* ]]
  [[ "$output" == *"scorecard"* ]]
}

@test "normalize_signature: non-array labels degrade to no labels (no crash)" {
  run normalize_signature "title" "null" "o/r"
  [ "$status" -eq 0 ]
  [[ "$output" == "title |  | o/r" ]]
}

# ---------------------------------------------------------------------------
# classify_by_rules — real-rules regression guard + ordering
# ---------------------------------------------------------------------------

@test "classify_by_rules: the bare dev-lead label does NOT match dev-lead agent" {
  # Signature as normalize_signature would produce it: gate label already gone.
  run classify_by_rules "some unrelated title |  | combsmith/.github"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classify_by_rules: sonarcloud title → Org Standards" {
  run classify_by_rules "sonarcloud: resolve remaining s7635 stubs |  | combsmith/.github"
  [ "$output" = "Org Standards" ]
}

@test "classify_by_rules: auto-rebase title → Auto-rebase" {
  run classify_by_rules "auto-rebase: unguarded conflict-comment aborts |  | x/y"
  [ "$output" = "Auto-rebase" ]
}

@test "classify_by_rules: pr-review title → pr-review agent" {
  run classify_by_rules "pr-review advisory bot review gate |  | x/y"
  [ "$output" = "pr-review agent" ]
}

@test "classify_by_rules: a dev-lead-agent title still matches via the word in the title" {
  run classify_by_rules "dev-lead deep-impl engine-error timeout |  | x/y"
  [ "$output" = "dev-lead agent" ]
}

@test "classify_by_rules: ordering — Compliance Blitz beats generic Compliance" {
  run classify_by_rules "compliance blitz 2026 backlog |  | x/y"
  [ "$output" = "Compliance Blitz" ]
}

@test "classify_by_rules: cross-cutting infra WINS over the product repo (SonarCloud in a product repo → Org Standards)" {
  # The key ordering guarantee: a SonarCloud sweep inside a product repo is
  # Org Standards work, not product work.
  run classify_by_rules "sonarcloud: shell script hygiene cleanup |  | combsmith/talkterm"
  [ "$output" = "Org Standards" ]
}

@test "classify_by_rules: a genuine product feature in the product repo → the product initiative" {
  run classify_by_rules "add spatial audio to the voice provider pipeline |  | combsmith/talkterm"
  [ "$output" = "TalkTerm" ]
}

@test "classify_by_rules: avatar idea draft (no repo) → TalkTerm" {
  run classify_by_rules "3d avatar evolution with lip-sync |  | draft"
  [ "$output" = "TalkTerm" ]
}

@test "classify_by_rules: beekeeping idea → Broodly, not TalkTerm (hive wins)" {
  run classify_by_rules "conversational voice assistant grounded in hive history |  | draft"
  [ "$output" = "Broodly" ]
}

@test "classify_by_rules: feature-ideation → Business Analyst" {
  run classify_by_rules "feat(feature-ideation): add curated source list for mary |  | combsmith/.github"
  [ "$output" = "Business Analyst" ]
}

@test "classify_by_rules: token cost report → Cost Observability, not Daily Reports" {
  run classify_by_rules "org-wide weekly token cost observatory report |  | combsmith/.github"
  [ "$output" = "Cost Observability" ]
}

@test "classify_by_rules: no match → empty output, exit 0" {
  run classify_by_rules "zzq nonsense placeholder widget |  | x/y"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classify_by_rules: missing rules file → 65" {
  RULES_FILE="${TT_TMP}/nope.tsv" run classify_by_rules "anything"
  [ "$status" -eq 65 ]
}

# ---------------------------------------------------------------------------
# theme_for + decide_for_signature
# ---------------------------------------------------------------------------

@test "theme_for: Auto-rebase rolls up to Compliance" {
  run theme_for "Auto-rebase"
  [ "$output" = "Compliance" ]
}

@test "theme_for: unknown initiative → empty" {
  run theme_for "Nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "decide_for_signature: matched → 'initiative<TAB>theme'" {
  run decide_for_signature "sonarcloud ruleset drift |  | x/y"
  [ "$status" -eq 0 ]
  [[ "$output" == "Org Standards"$'\t'"Fleet Operations" ]]
}

@test "decide_for_signature: unmatched → empty" {
  run decide_for_signature "zzq nonsense placeholder |  | x/y"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sweep_project — DRY_RUN: resolve + page only, correct tallies
# ---------------------------------------------------------------------------

setup_sweep_stub() {
  local fields="${TT_TMP}/fields.json" items="${TT_TMP}/items.json"
  write_fields_schema "$fields"
  write_items_page "$items" \
    '{"id":"PVTI_A","initiative":null,"content":{"__typename":"Issue","title":"SonarCloud: fix S7635 stubs","labels":{"nodes":[{"name":"dev-lead"}]},"repository":{"nameWithOwner":"combsmith/.github"}}}' \
    '{"id":"PVTI_B","initiative":{"name":"Auto-rebase"},"content":{"__typename":"PullRequest","title":"auto-rebase tweak","labels":{"nodes":[{"name":"dev-lead"}]},"repository":{"nameWithOwner":"combsmith/.github"}}}' \
    '{"id":"PVTI_C","initiative":null,"content":{"__typename":"DraftIssue","title":"zzq nonsense placeholder"}}'
  local script="${TT_TMP}/script.txt"
  {
    gh_script_line 0 "$fields" "-"   # resolve_fields
    gh_script_line 0 "$items" "-"    # paginate items
    gh_script_line 0 "-" "-"         # (apply) set Initiative on A
    gh_script_line 0 "-" "-"         # (apply) set Theme on A
  } >"$script"
  export GH_STUB_SCRIPT="$script"
}

@test "sweep_project DRY_RUN: tallies scanned/already/matched/unmatched, no mutations" {
  setup_sweep_stub
  DRY_RUN=1 run sweep_project
  [ "$status" -eq 0 ]
  [[ "$output" == *"board items scanned : 3"* ]]
  [[ "$output" == *"already associated  : 1"* ]]
  [[ "$output" == *"newly matched       : 1"* ]]
  [[ "$output" == *"unmatched (blank)   : 1"* ]]
  [[ "$output" == *"MATCH  Org Standards"* ]]
  [[ "$output" == *"UNMATCHED"* ]]
  # Only the two read calls (resolve + paginate); the mutations are dry-run.
  assert_invocation_count 2
}

@test "sweep_project apply: sets Initiative and Theme on the matched item" {
  setup_sweep_stub
  run sweep_project
  [ "$status" -eq 0 ]
  # resolve + paginate + set-initiative + set-theme
  assert_invocation_count 4
  assert_log_contains "updateProjectV2ItemFieldValue" "PVTI_A" "F_INIT" "o_orgstd"
  assert_log_contains "F_THEME" "t_fleet"
  # Never touches the already-associated or unmatched items.
  run grep -c PVTI_B "${GH_STUB_LOG}"
  [ "$output" = "0" ]
  run grep -c PVTI_C "${GH_STUB_LOG}"
  [ "$output" = "0" ]
}

@test "sweep_project: fails fast (75) when the project node is null" {
  local nullresp="${TT_TMP}/null.json"
  printf '%s' '{"data":{"node":null}}' >"$nullresp"
  local script="${TT_TMP}/script.txt"
  gh_script_line 0 "$nullresp" "-" >"$script"
  export GH_STUB_SCRIPT="$script"
  run sweep_project
  [ "$status" -eq 75 ]
}

@test "sweep_project: fails fast without GH_TOKEN" {
  unset GH_TOKEN
  run --separate-stderr sweep_project
  [ "$status" -eq 64 ]
  [[ "$stderr" == *"GH_TOKEN is empty"* ]]
}
