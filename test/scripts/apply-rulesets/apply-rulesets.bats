#!/usr/bin/env bats
# Unit tests for scripts/apply-rulesets.sh — the codified, file-driven applier that
# replaced the retired detection-based builder (combsmith/.github#580 / #575).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
APPLY="$SCRIPT_DIR/scripts/apply-rulesets.sh"
RULESETS_DIR="$SCRIPT_DIR/standards/rulesets"

setup() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
}
teardown() { [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; return 0; }

# gh stub: records writes (POST/PUT) to $CALLS (args line then --input body);
# returns $RULESETS_LIST for the rulesets LIST (default [] → create path);
# returns $RULESET_DETAIL for one ruleset by id (default {}; the literal FAIL
# makes that read fail); returns $REPO_LIST for `repo list`.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*)
    echo "\$args" >> "$CALLS"
    prev=""
    for arg in "\$@"; do
      [ "\$prev" = "--input" ] && { cat "\$arg" >> "$CALLS"; break; }
      prev="\$arg"
    done
    echo '{}' ;;
  *"repo list"*) printf '%s' "\${REPO_LIST:-}" ;;
  *"/rulesets/"*)
    [ "\${RULESET_DETAIL:-}" = "FAIL" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    empty='{}'; printf '%s' "\${RULESET_DETAIL:-\$empty}" ;;
  *"rulesets"*)  printf '%s' "\${RULESETS_LIST:-[]}" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# ── codified source of truth: shape + the anti-divergence guard (#580) ────────
@test "code-quality.json: requires exactly the 4 codified contexts" {
  run jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | sort | join(",")' "$RULESETS_DIR/code-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "CodeQL,SonarCloud,agent-shield / AgentShield,dependency-audit / Detect ecosystems" ]
}

@test "code-quality.json: does NOT require 'Dev-Lead Agent' (the retired divergence)" {
  run jq -e '[.rules[]?.parameters?.required_status_checks?[]?.context] | any(. // "" | test("Dev-Lead"))' "$RULESETS_DIR/code-quality.json"
  # jq `any` over no match exits 1 (false) — that is the pass condition.
  [ "$status" -ne 0 ]
}

@test "pr-quality.json + code-quality.json carry both bypass actors (OrgAdmin + Integration)" {
  local f
  for f in pr-quality code-quality; do
    run jq -e '[.bypass_actors[].actor_type] | (index("OrganizationAdmin") and index("Integration"))' "$RULESETS_DIR/$f.json"
    [ "$status" -eq 0 ]
  done
}

@test "pr-quality.json: allows squash merges only (allowed_merge_methods == [squash])" {
  # Anti-divergence guard (#771): the pr-quality ruleset enforces squash-only merges.
  # Widening this to include merge/rebase is exactly the drift the compliance audit's
  # check_ruleset_contents() flags. Lock the codified source of truth so it can never
  # silently regress to [merge, rebase, squash].
  run jq -c '.rules[]? | select(.type=="pull_request") | .parameters.allowed_merge_methods' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = '["squash"]' ]
}

@test "pr-quality.json: requires last-push approval (require_last_push_approval == true)" {
  # Anti-divergence guard (#957): the pr-quality ruleset requires that the last
  # push be re-approved, so a substantive push after approval cannot merge on the
  # stale review (github-settings.md#pr-quality). Flipping this to false is exactly
  # the drift the compliance audit's check_ruleset_contents() flags. Lock the
  # codified source of truth so it can never silently regress to false.
  run jq -r '.rules[]? | select(.type=="pull_request") | .parameters.require_last_push_approval' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "pr-quality.json: dismisses stale reviews on push (dismiss_stale_reviews_on_push == true)" {
  # Anti-divergence guard (#958): the pr-quality ruleset dismisses existing approvals
  # when a new commit is pushed, so a stale review cannot carry a substantive push to
  # merge (github-settings.md#pr-quality). Flipping this to false is exactly the drift
  # the compliance audit's check_ruleset_contents() flags. Lock the codified source of
  # truth so it can never silently regress to false.
  run jq -r '.rules[]? | select(.type=="pull_request") | .parameters.dismiss_stale_reviews_on_push' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "pr-quality.json: omits 'automatic_copilot_code_review_enabled' (Free-plan API rejects it)" {
  # GitHub's rulesets API 422s ("Unexpected parameter") on this pull_request
  # parameter for Free-plan orgs, which blocks apply-rulesets from creating or
  # updating pr-quality fleet-wide. It must stay out of the codified ruleset.
  run jq '.rules[] | select(.type=="pull_request") | .parameters | has("automatic_copilot_code_review_enabled")' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "release-channel-tags.json: tag ruleset, generic refs/tags/** include, update+deletion only" {
  run jq -er '.target == "tag"
    and (.conditions.ref_name.include == ["refs/tags/**"])
    and ([.rules[].type] | sort == ["deletion","update"])' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
}

@test "release-channel-tags.json: carries OrgAdmin + both Integration apps (automation 3167543 + release-manager 4193127)" {
  run jq -er '([.bypass_actors[] | select(.actor_type=="Integration") | .actor_id] | sort == [3167543,4193127])
    and ([.bypass_actors[].actor_type] | index("OrganizationAdmin"))' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
}

# ── repo self-host guard: dependency-audit.yml publishes the codified context ─
# code-quality.json requires `dependency-audit / Detect ecosystems` (asserted
# above). GitHub composes that context as `<caller-job-id> / <reusable-job
# displayName>`, so this repo's OWN dependency-audit.yml must be the thin caller
# stub (job id `dependency-audit` → dependency-audit-reusable.yml, whose detect
# job is displayName "Detect ecosystems"), matching agent-shield.yml's self-host
# pattern. The pre-centralization inline workflow ran a top-level `detect` job
# directly, publishing the bare `Detect ecosystems` context and drifting the
# live ruleset off the codified name (#772).
DEP_AUDIT_WF="$SCRIPT_DIR/.github/workflows/dependency-audit.yml"

@test "dependency-audit.yml: is a caller stub with job 'dependency-audit' using the reusable" {
  run grep -Eq '^  dependency-audit:[[:space:]]*$' "$DEP_AUDIT_WF"
  [ "$status" -eq 0 ]
  run grep -Eq '^[[:space:]]*uses:[[:space:]]*.*dependency-audit-reusable\.yml' "$DEP_AUDIT_WF"
  [ "$status" -eq 0 ]
}

@test "dependency-audit.yml: carries no inline 'detect' job (would publish bare 'Detect ecosystems')" {
  run grep -Eq '^  detect:[[:space:]]*$' "$DEP_AUDIT_WF"
  [ "$status" -eq 1 ]
}

# ── apply behavior: create / update / dry-run ─────────────────────────────────
@test "apply --repo: creates rulesets when absent (POST per file)" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"done (2 ruleset(s))"* ]]
  [ "$(grep -c 'method POST' "$CALLS")" -eq 2 ]
  ! grep -q 'method PUT' "$CALLS"
}

@test "apply --repo: updates when present (PUT by id)" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"},{"id":9,"name":"pr-quality"}]'
  run bash "$APPLY" --repo combsmith/acme
  [ "$status" -eq 0 ]
  grep -q 'method PUT' "$CALLS"
  ! grep -q 'method POST' "$CALLS"
}

@test "apply: --dry-run makes no write calls" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/acme --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
  [[ "$output" == *"dry-run"* ]]
}

@test "apply --repo: pr-quality POST payload includes dismiss_stale_reviews_on_push=true" {
  # Verifies that apply-rulesets.sh actually sends dismiss_stale_reviews_on_push in
  # the request body — not just that the field exists in the checked-in JSON. If the
  # script ever strips or transforms the payload before sending, this test catches it.
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/acme pr-quality
  [ "$status" -eq 0 ]
  jq -e '
    any(.rules[]?;
      .type == "pull_request" and
      .parameters.dismiss_stale_reviews_on_push == true)
  ' < <(tail -n +2 "$CALLS") >/dev/null
}

# ── target resolution: bare name (back-compat) + name filter ──────────────────
@test "apply: a bare <repo-name> resolves to \$ORG/<name>" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" acme --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=combsmith/acme"* ]]
}

@test "apply: a name filter applies only that ruleset" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/acme code-quality --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-quality"* ]]
  [[ "$output" != *"pr-quality"* ]]
  [[ "$output" == *"done (1 ruleset(s))"* ]]
}

@test "apply: default set is the fleet allowlist only — release-channel-tags is NOT swept in" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/acme
  [ "$status" -eq 0 ]
  # code-quality + pr-quality applied; release-channel-tags excluded despite being in the dir.
  [[ "$output" == *"done (2 ruleset(s))"* ]]
  [[ "$output" != *"release-channel-tags"* ]]
}

@test "apply: release-channel-tags applies only when named explicitly" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/.github release-channel-tags --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-channel-tags"* ]]
  [[ "$output" == *"done (1 ruleset(s))"* ]]
}

@test "apply: unknown ruleset name errors" {
  _stub_gh
  run bash "$APPLY" --repo combsmith/acme no-such-ruleset
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ruleset file no-such-ruleset.json"* ]]
}

# ── fleet mode ────────────────────────────────────────────────────────────────
@test "apply --all: iterates every non-archived org repo" {
  _stub_gh
  export RULESETS_LIST='[]' REPO_LIST=$'alpha\nbeta'
  run bash "$APPLY" --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=combsmith/alpha"* ]]
  [[ "$output" == *"repo=combsmith/beta"* ]]
  [[ "$output" == *"across the fleet"* ]]
}

@test "apply: --all and --repo are mutually exclusive" {
  _stub_gh
  run bash "$APPLY" --all --repo combsmith/acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "apply: a bare token after --all is a ruleset-name filter (unknown → errors)" {
  _stub_gh
  export REPO_LIST=$'alpha'
  run bash "$APPLY" --all not-a-ruleset --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ruleset file not-a-ruleset.json"* ]]
}

# ── sourced helpers ───────────────────────────────────────────────────────────
@test "ruleset_id_by_name: resolves id from the list" {
  _stub_gh
  export RULESETS_LIST='[{"id":42,"name":"pr-quality"},{"id":7,"name":"code-quality"}]'
  run bash -c "source '$APPLY' && ruleset_id_by_name combsmith/acme code-quality"
  [ "$status" -eq 0 ]; [ "$output" = "7" ]
}

# ── code-scanning merge protection: a floor, never lowered ────────────────────
# code-quality.json's code_scanning rule (standards/github-settings.md
# #code-scanning-merge-protection-all-repositories) is a minimum. A full-replace
# PUT would lower a repo that is stricter (security_alerts_threshold `all`), so
# an update keeps the stricter live value (cs_floor_payload).

# _put_body — the JSON body of the single recorded PUT/POST.
_put_body() { tail -n +2 "$CALLS"; }

# _live_cq <security_alerts_threshold> <alerts_threshold> — a live code-quality ruleset.
_live_cq() {
  jq -c --arg s "$1" --arg a "$2" \
    '.id = 7 | .rules |= map(if .type == "code_scanning"
       then .parameters.code_scanning_tools = [{tool:"CodeQL",security_alerts_threshold:$s,alerts_threshold:$a}]
       else . end)' "$RULESETS_DIR/code-quality.json"
}

@test "code-quality.json: code_scanning rule is CodeQL, medium_or_higher, errors" {
  run jq -c '[.rules[] | select(.type=="code_scanning") | .parameters.code_scanning_tools[]]' "$RULESETS_DIR/code-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"tool":"CodeQL","security_alerts_threshold":"medium_or_higher","alerts_threshold":"errors"}]' ]
}

@test "apply --repo: create POSTs the code_scanning rule" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo combsmith/acme code-quality
  [ "$status" -eq 0 ]
  run jq -r '.rules[] | select(.type=="code_scanning") | .parameters.code_scanning_tools[0].security_alerts_threshold' < <(_put_body)
  [ "$output" = "medium_or_higher" ]
}

@test "apply --repo: update keeps a stricter live security threshold (all), never lowers it" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"}]'
  RULESET_DETAIL="$(_live_cq all errors)"; export RULESET_DETAIL
  run bash "$APPLY" --repo combsmith/acme code-quality
  [ "$status" -eq 0 ]
  grep -q 'method PUT' "$CALLS"
  run jq -c '.rules[] | select(.type=="code_scanning") | .parameters.code_scanning_tools[0]' < <(_put_body)
  [ "$output" = '{"tool":"CodeQL","security_alerts_threshold":"all","alerts_threshold":"errors"}' ]
}

@test "apply --repo: update keeps a stricter live alerts threshold (errors_and_warnings)" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"}]'
  RULESET_DETAIL="$(_live_cq medium_or_higher errors_and_warnings)"; export RULESET_DETAIL
  run bash "$APPLY" --repo combsmith/acme code-quality
  [ "$status" -eq 0 ]
  run jq -r '.rules[] | select(.type=="code_scanning") | .parameters.code_scanning_tools[0].alerts_threshold' < <(_put_body)
  [ "$output" = "errors_and_warnings" ]
}

@test "apply --repo: update raises a weaker live threshold (high_or_higher) to the floor" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"}]'
  RULESET_DETAIL="$(_live_cq high_or_higher none)"; export RULESET_DETAIL
  run bash "$APPLY" --repo combsmith/acme code-quality
  [ "$status" -eq 0 ]
  run jq -c '.rules[] | select(.type=="code_scanning") | .parameters.code_scanning_tools[0]' < <(_put_body)
  [ "$output" = '{"tool":"CodeQL","security_alerts_threshold":"medium_or_higher","alerts_threshold":"errors"}' ]
}

@test "apply --repo: update over a live ruleset with no code_scanning rule PUTs the file as is" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"}]'
  export RULESET_DETAIL='{"id":7,"name":"code-quality","rules":[{"type":"required_status_checks","parameters":{}}]}'
  run bash "$APPLY" --repo combsmith/acme code-quality
  [ "$status" -eq 0 ]
  [ "$(_put_body | jq -cS .)" = "$(jq -cS . "$RULESETS_DIR/code-quality.json")" ]
}

@test "apply --repo: an unreadable live ruleset is not updated (nothing stricter is lowered)" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"}]' RULESET_DETAIL='FAIL'
  run bash "$APPLY" --repo combsmith/acme code-quality
  [ "$status" -ne 0 ]
  [[ "$output" == *"not updating it"* ]]
  [ ! -f "$CALLS" ]
}

@test "apply: --dry-run says when it keeps a stricter live threshold, and writes nothing" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"}]'
  RULESET_DETAIL="$(_live_cq all errors)"; export RULESET_DETAIL
  run bash "$APPLY" --repo combsmith/acme code-quality --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
  [[ "$output" == *"keeps the live, stricter code_scanning thresholds"* ]]
  [[ "$output" == *'"security_alerts_threshold":"all"'* ]]
}

@test "cs_floor_payload: ignores an unknown live value and another tool's entry" {
  run bash -c "source '$APPLY' && cs_floor_payload '$RULESETS_DIR/code-quality.json' \
    '{\"rules\":[{\"type\":\"code_scanning\",\"parameters\":{\"code_scanning_tools\":[{\"tool\":\"CodeQL\",\"security_alerts_threshold\":\"bogus\",\"alerts_threshold\":\"errors\"},{\"tool\":\"Semgrep\",\"security_alerts_threshold\":\"all\",\"alerts_threshold\":\"all\"}]}}]}' \
    | jq -c '.rules[] | select(.type==\"code_scanning\") | .parameters.code_scanning_tools'"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"tool":"CodeQL","security_alerts_threshold":"medium_or_higher","alerts_threshold":"errors"}]' ]
}
