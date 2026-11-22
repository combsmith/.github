#!/usr/bin/env bats
# Tests for check_ruleset_bypass_actors in scripts/compliance-audit.sh, and the
# Dependabot auto-merge App rename (#1545).
#
# The App was renamed with the org to `combsmith-dependabot-automrg`
# (app_id 3167543). The audit must match it on the stable App id, never on its
# name, so a future rename cannot break the check. The finding ids
# (`ruleset-bypass-dependabot-<slug>`, `ruleset-bypass-dependabot-mode-<slug>`)
# are matched against open findings and must not change.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

NEW_APP_NAME="combsmith-dependabot-automrg"
# The pre-rename name, built from two parts so this file never matches itself.
OLD_APP_NAME="dependabot-automerge""-petry"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/ruleset-bypass.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _ruleset <dependabot_bypass_actor_json_or_empty>
# A pr-quality ruleset targeting ~DEFAULT_BRANCH with a correct OrganizationAdmin
# bypass plus the given Integration bypass actor (if any).
_ruleset() {
  local extra="${1:-}"
  jq -cn --argjson extra "${extra:-null}" '
    {id: 42, name: "pr-quality",
     conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
     bypass_actors: ([{actor_id: 1, actor_type: "OrganizationAdmin", bypass_mode: "always"}]
                     + (if $extra == null then [] else [$extra] end))}'
}

# _run_check <ruleset_json>
# Mock `gh` serves <ruleset_json> for rulesets/42, sources the real audit, runs
# check_ruleset_bypass_actors, and prints findings.json.
_run_check() {
  printf '%s' "$1" > "$TEST_TMP/ruleset.json"
  cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
path=""
for a in "\$@"; do
  case "\$a" in --*|api) : ;; *) path="\$a" ;; esac
done
case "\$path" in
  */rulesets/42) cat "$TEST_TMP/ruleset.json" ;;
  *) echo '[]' ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_ruleset_bypass_actors "demo-repo" "main" "[{\"id\":42}]"
    cat "$REPORT_DIR/findings.json"
  '
}

_dep_ids() {
  jq -r '[.[] | .check | select(startswith("ruleset-bypass-dependabot"))] | .[]' <<< "$1"
}

@test "audit matches the Dependabot App on actor_id 3167543" {
  run grep -E '^DEPENDABOT_APP_ACTOR_ID=3167543$' "$REPO_ROOT/scripts/compliance-audit.sh"
  [ "$status" -eq 0 ]
}

@test "Integration actor_id 3167543 with bypass_mode always → no dependabot finding" {
  run _run_check "$(_ruleset '{"actor_id":3167543,"actor_type":"Integration","bypass_mode":"always"}')"
  [ "$status" -eq 0 ]
  jq -e 'type == "array"' <<< "$output"
  [ -z "$(_dep_ids "$output")" ]
  # The OrganizationAdmin bypass is correct too, so the ruleset is fully clean.
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
}

@test "Integration actor with a different actor_id → ruleset-bypass-dependabot-<slug>" {
  run _run_check "$(_ruleset '{"actor_id":9999999,"actor_type":"Integration","bypass_mode":"always"}')"
  [ "$status" -eq 0 ]
  [ "$(_dep_ids "$output")" = "ruleset-bypass-dependabot-pr-quality" ]
}

@test "no Integration bypass actor at all → ruleset-bypass-dependabot-<slug>" {
  run _run_check "$(_ruleset '')"
  [ "$status" -eq 0 ]
  [ "$(_dep_ids "$output")" = "ruleset-bypass-dependabot-pr-quality" ]
}

@test "Integration actor_id 3167543 with bypass_mode pull_request → ruleset-bypass-dependabot-mode-<slug>" {
  run _run_check "$(_ruleset '{"actor_id":3167543,"actor_type":"Integration","bypass_mode":"pull_request"}')"
  [ "$status" -eq 0 ]
  [ "$(_dep_ids "$output")" = "ruleset-bypass-dependabot-mode-pr-quality" ]
}

@test "dependabot finding messages name the App by its current name" {
  run _run_check "$(_ruleset '')"
  [ "$status" -eq 0 ]
  detail="$(jq -r '.[] | select(.check | startswith("ruleset-bypass-dependabot")) | .detail' <<< "$output")"
  [[ "$detail" == *"$NEW_APP_NAME"* ]]
  [[ "$detail" != *"$OLD_APP_NAME"* ]]

  run _run_check "$(_ruleset '{"actor_id":3167543,"actor_type":"Integration","bypass_mode":"pull_request"}')"
  detail="$(jq -r '.[] | select(.check | startswith("ruleset-bypass-dependabot")) | .detail' <<< "$output")"
  [[ "$detail" == *"$NEW_APP_NAME"* ]]
  [[ "$detail" != *"$OLD_APP_NAME"* ]]
}

# ---------------------------------------------------------------------------
# No tracked file still uses the pre-rename App name
# ---------------------------------------------------------------------------
# Lines that legitimately record the rename, as `path:line-content`. Empty: no
# history/migration note has been added.
RENAME_ALLOWLIST=()

@test "no tracked file refers to the App by its old name (outside the allowlist)" {
  if ! command -v git >/dev/null 2>&1; then
    skip "git command not found"
  fi
  cd "$REPO_ROOT"
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "Not in a git repository"
  fi
  hits="$(git grep -I -i -F "$OLD_APP_NAME" -- . || true)"
  unexpected=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    allowed=0
    for a in "${RENAME_ALLOWLIST[@]}"; do
      [ "$line" = "$a" ] && allowed=1
    done
    [ "$allowed" -eq 0 ] && unexpected+="$line"$'\n'
  done <<< "$hits"
  if [ -n "$unexpected" ]; then
    echo "Old App name still present:" >&2
    printf '%s' "$unexpected" >&2
    return 1
  fi
}
