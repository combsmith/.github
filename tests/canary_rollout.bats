#!/usr/bin/env bats
# Unit tests for the canary-rollout decision core (scripts/lib/canary-rollout.sh)
# and the scripts/canary-rollout.sh orchestrator's pure paths (with gh stubs).
# Initiative #495 · issues #501 (promotion) / #502 (rollback + observability).
# Gate standard: .github#548 (graduated dwell/sample, robust baseline,
# per-candidate cumulative window, ring0 sample waiver, failure triage).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/canary-rollout.sh"
ORCH="$SCRIPT_DIR/scripts/canary-rollout.sh"
RINGS="$SCRIPT_DIR/standards/canary-rings.json"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── clamp ─────────────────────────────────────────────────────────────────────
@test "clamp: within range is unchanged" { [ "$(clamp 7 3 15)" -eq 7 ]; }
@test "clamp: below floor snaps to floor" { [ "$(clamp 1 3 15)" -eq 3 ]; }
@test "clamp: above ceiling snaps to ceiling" { [ "$(clamp 25 3 15)" -eq 15 ]; }
@test "clamp: at bounds is inclusive" { [ "$(clamp 3 3 15)" -eq 3 ]; [ "$(clamp 15 3 15)" -eq 15 ]; }

# ── round_div (banker-free half-up rounding) ──────────────────────────────────
@test "round_div: exact" { [ "$(round_div 10 5)" -eq 2 ]; }
@test "round_div: rounds half up" { [ "$(round_div 5 2)" -eq 3 ]; [ "$(round_div 7 2)" -eq 4 ]; }
@test "round_div: rounds down below half" { [ "$(round_div 4 3)" -eq 1 ]; }
@test "round_div: zero denominator → 0 + nonzero rc" {
  run round_div 5 0
  [ "$status" -ne 0 ]; [ "$output" -eq 0 ]
}

# ── median_x2 (2×median, exact integer even for even-length sets) ──────────────
@test "median_x2: odd length" { [ "$(median_x2 1 5 3)" -eq 6 ]; }   # median 3 → 6
@test "median_x2: even length sums the two middles" { [ "$(median_x2 4 4 4 4)" -eq 8 ]; }  # 4+4
@test "median_x2: unsorted input" { [ "$(median_x2 40 2 2 40 2 2)" -eq 4 ]; } # sorted middles 2,2
@test "median_x2: empty → 0" { [ "$(median_x2)" -eq 0 ]; }

# ── robust_sample_target: robust baseline = spike-capped mean, then clamp ──────
# fraction_permille=250 (0.25), clamp [3,15].
@test "robust_sample_target: steady volume → round(0.25·avg)" {
  # 14 days all = 40 → avg 40 → 0.25·40 = 10 → clamp 10
  set -- 40 40 40 40 40 40 40 40 40 40 40 40 40 40
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 10 ]
}
@test "robust_sample_target: below floor clamps up to 3" {
  set -- 4 4 4 4 4 4 4 4 4 4 4 4 4 4   # avg 4 → 0.25·4 = 1 → clamp 3
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 3 ]
}
@test "robust_sample_target: above ceiling clamps down to 15" {
  set -- 100 100 100 100 100 100 100 100 100 100 100 100 100 100  # 25 → clamp 15
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 15 ]
}
@test "robust_sample_target: a 2500-run loop day is capped at 3× median (not inflated to 15)" {
  # 13 low days of 2 + one 2500-run loop day. Robust baseline caps the spike at
  # 3× median (=6), so the target stays a reachable 3 — NOT the 15 a raw mean gives.
  set -- 2 2 2 2 2 2 2 2 2 2 2 2 2 2500
  [ "$(robust_sample_target 250 3 15 3 "$@")" -eq 3 ]
  # sanity: the naive (uncapped) mean would blow past the ceiling
  local sum=0 n=0 c; for c in "$@"; do sum=$((sum+c)); n=$((n+1)); done
  [ "$(clamp "$(round_div $((250*sum)) $((1000*n)))" 3 15)" -eq 15 ]
}

# ── version-bump math (autocut front end, #1069) ──────────────────────────────
@test "bump_version: patch increments the patch component" {
  [ "$(bump_version 2.1.0 patch)" = "2.1.1" ]
  [ "$(bump_version 0.0.0 patch)" = "0.0.1" ]
}
@test "bump_version: minor increments minor and zeroes patch" {
  [ "$(bump_version 2.1.3 minor)" = "2.2.0" ]
}
@test "bump_version: major increments major and zeroes minor+patch" {
  [ "$(bump_version 2.1.3 major)" = "3.0.0" ]
}
@test "bump_version: default (no/unknown level) is patch" {
  [ "$(bump_version 2.1.0)" = "2.1.1" ]
  [ "$(bump_version 2.1.0 bogus)" = "2.1.1" ]
}

# ── decide_bump: signal-based classification, knob as override (#712, epic #1083) ─
# decide_bump <breaking 0|1> <feat 0|1> <override> → major|minor|patch.
# An explicit override (patch|minor|major) always wins; else breaking→major, feat→minor,
# else patch. All 4 signal combinations plus override precedence are exercised.
@test "decide_bump: breaking beats feat → major (both signals set)" {
  [ "$(decide_bump 1 1 '')" = "major" ]
}
@test "decide_bump: breaking only → major" {
  [ "$(decide_bump 1 0 '')" = "major" ]
}
@test "decide_bump: feat only → minor" {
  [ "$(decide_bump 0 1 '')" = "minor" ]
}
@test "decide_bump: neither signal → patch" {
  [ "$(decide_bump 0 0 '')" = "patch" ]
}
@test "decide_bump: override wins over every signal combination" {
  # override major
  [ "$(decide_bump 0 0 major)" = "major" ]
  [ "$(decide_bump 1 1 major)" = "major" ]
  # override minor (even when breaking would say major)
  [ "$(decide_bump 1 0 minor)" = "minor" ]
  [ "$(decide_bump 0 0 minor)" = "minor" ]
  # override patch (even when breaking/feat would escalate)
  [ "$(decide_bump 1 1 patch)" = "patch" ]
  [ "$(decide_bump 0 1 patch)" = "patch" ]
}
@test "decide_bump: an invalid override is ignored (falls back to signals)" {
  [ "$(decide_bump 1 0 bogus)" = "major" ]
  [ "$(decide_bump 0 1 '')"   = "minor" ]
}

# ── promotion tag-write failure streak: pure escalation cores (#1023 defect 2) ───
@test "promotion_failure_next_count: a failed write increments the streak" {
  [ "$(promotion_failure_next_count 0 failed)" -eq 1 ]
  [ "$(promotion_failure_next_count 2 failed)" -eq 3 ]
}
@test "promotion_failure_next_count: a successful write resets the streak to 0" {
  [ "$(promotion_failure_next_count 5 ok)" -eq 0 ]
}
@test "promotion_failure_next_count: a non-numeric prior count is treated as 0" {
  [ "$(promotion_failure_next_count '' failed)" -eq 1 ]
  [ "$(promotion_failure_next_count 'x' failed)" -eq 1 ]
}
@test "promotion_failure_should_escalate: fires only at/after the threshold" {
  [ "$(promotion_failure_should_escalate 1 2)" -eq 0 ]
  [ "$(promotion_failure_should_escalate 2 2)" -eq 1 ]
  [ "$(promotion_failure_should_escalate 3 2)" -eq 1 ]
}
@test "promotion_failure_should_escalate: a sub-1 threshold clamps to 1; bad input → 0" {
  [ "$(promotion_failure_should_escalate 1 0)" -eq 1 ]
  [ "$(promotion_failure_should_escalate 'x' 2)" -eq 0 ]
  [ "$(promotion_failure_should_escalate 2 'y')" -eq 0 ]
}

# ── commit_page_done: pagination termination decision (#1023) ─────────────────
@test "commit_page_done: returns 1 (done) when the boundary commit is found" {
  ! commit_page_done "true" 100 100
}
@test "commit_page_done: returns 1 (done) when the page is short (< per_page)" {
  ! commit_page_done "false" 42 100
  ! commit_page_done "false" 0 100
}
@test "commit_page_done: returns 0 (continue) when page is full and boundary not found" {
  commit_page_done "false" 100 100
}
@test "commit_page_done: returns 1 (done) on a boundary-found full page" {
  ! commit_page_done "true" 100 100
}

# ── workflow_call_iface: parse an on.workflow_call interface into a descriptor ────
# Pure YAML→descriptor transform: emits `input <name> <req 0|1>` and `secret <name>`
# (sorted). Outputs are intentionally not emitted (they never drive a breaking verdict).
@test "workflow_call_iface: extracts inputs (with required flags) and secrets" {
  yaml="$(cat <<'YML'
name: demo-reusable
on:
  workflow_call:
    inputs:
      target:
        required: true
        type: string
      dry_run:
        required: false
        type: boolean
      note:
        type: string
    secrets:
      APP_TOKEN:
        required: true
    outputs:
      result:
        value: ${{ jobs.x.outputs.r }}
jobs:
  x:
    runs-on: ubuntu-latest
    steps: []
YML
)"
  run workflow_call_iface "$yaml"
  [ "$status" -eq 0 ]
  # required input → req 1; optional / unspecified → req 0
  [[ "$output" == *"input target 1"* ]]
  [[ "$output" == *"input dry_run 0"* ]]
  [[ "$output" == *"input note 0"* ]]
  [[ "$output" == *"secret APP_TOKEN"* ]]
  # outputs are not part of the interface descriptor
  [[ "$output" != *"result"* ]]
}

# ── interface_break: decide a breaking workflow_call interface change ─────────────
# interface_break <old_desc> <new_desc> → 1 if an input/secret was removed or renamed,
# or an input became (or was newly added as) required:true; else 0. Added-optional
# inputs and new outputs are NOT breaking.
@test "interface_break: removed input → breaking" {
  old="$(printf 'input a 0\ninput b 0\n')"
  new="$(printf 'input a 0\n')"
  [ "$(interface_break "$old" "$new")" = "1" ]
}
@test "interface_break: renamed input (drop old name, add new) → breaking" {
  old="$(printf 'input a 0\n')"
  new="$(printf 'input renamed 0\n')"
  [ "$(interface_break "$old" "$new")" = "1" ]
}
@test "interface_break: removed secret → breaking" {
  old="$(printf 'secret TOKEN\n')"
  new="$(printf '')"
  [ "$(interface_break "$old" "$new")" = "1" ]
}
@test "interface_break: newly-added required input → breaking" {
  old="$(printf 'input a 0\n')"
  new="$(printf 'input a 0\ninput b 1\n')"
  [ "$(interface_break "$old" "$new")" = "1" ]
}
@test "interface_break: optional input flipped to required → breaking" {
  old="$(printf 'input a 0\n')"
  new="$(printf 'input a 1\n')"
  [ "$(interface_break "$old" "$new")" = "1" ]
}
@test "interface_break: added OPTIONAL input → NOT breaking" {
  old="$(printf 'input a 0\n')"
  new="$(printf 'input a 0\ninput b 0\n')"
  [ "$(interface_break "$old" "$new")" = "0" ]
}
@test "interface_break: identical interface → NOT breaking" {
  desc="$(printf 'input a 1\nsecret TOKEN\n')"
  [ "$(interface_break "$desc" "$desc")" = "0" ]
}
@test "interface_break: required input relaxed to optional → NOT breaking" {
  old="$(printf 'input a 1\n')"
  new="$(printf 'input a 0\n')"
  [ "$(interface_break "$old" "$new")" = "0" ]
}

@test "_semver_gt: compares by major, then minor, then patch" {
  run _semver_gt 2.1.1 2.1.0; [ "$status" -eq 0 ]
  run _semver_gt 2.2.0 2.1.9; [ "$status" -eq 0 ]
  run _semver_gt 3.0.0 2.9.9; [ "$status" -eq 0 ]
  run _semver_gt 2.1.0 2.1.0; [ "$status" -ne 0 ]   # equal is not greater
  run _semver_gt 2.1.0 2.1.1; [ "$status" -ne 0 ]
}

@test "max_semver: picks the highest version" {
  [ "$(max_semver 2.0.5 2.1.0 2.0.9)" = "2.1.0" ]
  [ "$(max_semver 1.0.0)" = "1.0.0" ]
}
@test "max_semver: ignores non-semver tokens" {
  [ "$(max_semver 2.1.0 not-a-version 2.1.5 v3.0.0)" = "2.1.5" ]
}
@test "max_semver: empty input → empty" {
  [ -z "$(max_semver)" ]
}

# ── dwell_met ─────────────────────────────────────────────────────────────────
@test "dwell_met: at/over floor → 1" { [ "$(dwell_met 4 4)" -eq 1 ]; [ "$(dwell_met 9 8)" -eq 1 ]; }
@test "dwell_met: under floor → 0" { [ "$(dwell_met 3 4)" -eq 0 ]; }

# ── iso_after (per-candidate cumulative window predicate) ──────────────────────
@test "iso_after: strictly-after and equal are 'yes'" {
  [ "$(iso_after 2026-06-28T00:00:00Z 2026-06-28T00:00:00Z)" = yes ]
  [ "$(iso_after 2026-06-29T00:00:00Z 2026-06-28T00:00:00Z)" = yes ]
}
@test "iso_after: excludes a pre-cut failure (pr-review-mention 06-27 before v2.1.1 06-28 cut)" {
  # A run on 06-27 is NOT after the 06-28 candidate cut → must be excluded.
  [ "$(iso_after 2026-06-27T10:00:00Z 2026-06-28T00:00:00Z)" = no ]
}

# ── decide_graduated (dwell + sample + cumulative-health) ─────────────────────
# args: <dwell_h> <dwell_floor> <sample> <sample_target> <sample_waived> <cum_fail> <cum_startup>
@test "decide_graduated: dwell+sample met, clean → PROMOTE" {
  [ "$(decide_graduated 5 4 8 3 false 0 0)" = "PROMOTE" ]
}
@test "decide_graduated: dwell short → SOAKING" {
  [ "$(decide_graduated 3 4 8 3 false 0 0)" = "SOAKING" ]
}
@test "decide_graduated: sample short → SOAKING" {
  [ "$(decide_graduated 5 4 2 3 false 0 0)" = "SOAKING" ]
}
@test "decide_graduated: any cumulative failure → BLOCKED (beats dwell+sample)" {
  [ "$(decide_graduated 99 4 99 3 false 1 0)" = "BLOCKED" ]
  [ "$(decide_graduated 99 4 99 3 false 0 1)" = "BLOCKED" ]
}
@test "decide_graduated: ring0→ring1 waives the fresh sample (cumulative-clean + dwell only)" {
  # sample 0 but waived → PROMOTE once dwell met and clean.
  [ "$(decide_graduated 9 8 0 0 true 0 0)" = "PROMOTE" ]
  # still blocks on a cumulative failure even when waived.
  [ "$(decide_graduated 9 8 0 0 true 1 0)" = "BLOCKED" ]
  # still soaks if dwell not met.
  [ "$(decide_graduated 5 8 0 0 true 0 0)" = "SOAKING" ]
}

# ── classify_failure (triage: regression vs pre-existing/environmental/suspect) ─
# args: <reusable_differs 0|1> <category> [suspect_match 0|1]
@test "classify_failure: reusable changed + non-environmental → REGRESSION" {
  [ "$(classify_failure 1 unknown)" = "REGRESSION" ]
}
@test "classify_failure: reusable identical to prior version → PRE_EXISTING" {
  [ "$(classify_failure 0 unknown)" = "PRE_EXISTING" ]
}
@test "classify_failure: environmental category → PRE_EXISTING even if reusable changed" {
  [ "$(classify_failure 1 comment-cap)" = "PRE_EXISTING" ]
  [ "$(classify_failure 1 rate-limit)" = "PRE_EXISTING" ]
  [ "$(classify_failure 1 infra)" = "PRE_EXISTING" ]
  [ "$(classify_failure 1 data)" = "PRE_EXISTING" ]
}

# ── classify_failure: SUSPECT third verdict (#668 increment 2, #675) ────────────
# A suspect-class match at differs=1 becomes SUSPECT instead of REGRESSION — it still
# BLOCKS + needs a human, but carries a discriminating question so the confirm is fast.
@test "classify_failure: suspect match + reusable changed → SUSPECT (not REGRESSION)" {
  [ "$(classify_failure 1 unknown 1)" = "SUSPECT" ]
}
@test "classify_failure: NO suspect match + reusable changed → still REGRESSION" {
  [ "$(classify_failure 1 unknown 0)" = "REGRESSION" ]
}
@test "classify_failure: suspect match but reusable identical → PRE_EXISTING (can't be candidate-caused)" {
  [ "$(classify_failure 0 unknown 1)" = "PRE_EXISTING" ]
}
@test "classify_failure: environmental category beats a suspect match → PRE_EXISTING" {
  [ "$(classify_failure 1 infra 1)" = "PRE_EXISTING" ]
}
@test "classify_failure: suspect arg defaults to 0 (omitted) → REGRESSION at differs=1" {
  [ "$(classify_failure 1 unknown)" = "REGRESSION" ]
}

# ── decide_suspect_downgrade (SUSPECT→PRE_EXISTING auto-downgrade, #668 increment 6) ─
# args: <cand_rate_permille> <base_rate_permille> <base_sample> <knobs_json>
# Applied AFTER classify_failure returns SUSPECT (keeps the verdict core small). DOWNGRADE only
# when the candidate is statistically no-worse than the prior version AND the baseline is not
# too thin (tiny-n guard); otherwise HOLD (stay SUSPECT, increment 2 behaviour).
DG_KNOBS='{"min_baseline_sample":10,"margin_permille":100}'

@test "decide_suspect_downgrade: cand no worse than base+margin, sample≥min → DOWNGRADE" {
  [ "$(decide_suspect_downgrade 100 100 10 "$DG_KNOBS")" = "DOWNGRADE" ]
  [ "$(decide_suspect_downgrade 50 100 25 "$DG_KNOBS")" = "DOWNGRADE" ]
}
@test "decide_suspect_downgrade: cand materially worse than base+margin → HOLD (stay SUSPECT)" {
  [ "$(decide_suspect_downgrade 500 100 10 "$DG_KNOBS")" = "HOLD" ]
  [ "$(decide_suspect_downgrade 201 100 10 "$DG_KNOBS")" = "HOLD" ]
}
@test "decide_suspect_downgrade: thin baseline (base_sample < min) → HOLD (tiny-n guard)" {
  # Even a candidate rate of 0 must NOT downgrade on too little baseline data.
  [ "$(decide_suspect_downgrade 0 100 9 "$DG_KNOBS")" = "HOLD" ]
  [ "$(decide_suspect_downgrade 100 100 5 "$DG_KNOBS")" = "HOLD" ]
}
@test "decide_suspect_downgrade: boundary at exactly base+margin → DOWNGRADE (inclusive)" {
  # margin 100, base 100 → threshold 200; cand==200 downgrades, cand==201 holds.
  [ "$(decide_suspect_downgrade 200 100 10 "$DG_KNOBS")" = "DOWNGRADE" ]
  [ "$(decide_suspect_downgrade 201 100 10 "$DG_KNOBS")" = "HOLD" ]
}
@test "decide_suspect_downgrade: sample exactly at min → not thin (DOWNGRADE when no worse)" {
  [ "$(decide_suspect_downgrade 100 100 10 "$DG_KNOBS")" = "DOWNGRADE" ]
}
@test "decide_suspect_downgrade: absent/empty knobs default to margin 0 + no tiny-n guard" {
  # margin 0 → strict no-worse; min_baseline_sample 0 → any sample passes the guard.
  [ "$(decide_suspect_downgrade 100 100 0 '{}')" = "DOWNGRADE" ]
  [ "$(decide_suspect_downgrade 101 100 0 '{}')" = "HOLD" ]
  [ "$(decide_suspect_downgrade 100 100 0 '')" = "DOWNGRADE" ]
}

# ── _reusable_differs: cross-repo host-aware blob compare (#613) ───────────────
# When an agent's host != THIS_REPO (e.g. dev-lead hosted in .github-private while the
# engine runs from .github), the reusable blob is NOT in the local checkout — the compare
# must go through `gh api` on the host. agent-shield (host = petry-projects/.github) is the
# cross-repo agent here, with THIS_REPO forced to .github-private via GITHUB_REPOSITORY.
@test "_reusable_differs: cross-repo agent resolves host blobs via gh api — differ → 1" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    echo '  *"ref=CAND"*)  echo "aaaaaaaaaa" ;;'
    echo '  *"ref=PRIOR"*) echo "bbbbbbbbbb" ;;'
    echo '  *) echo "" ;;'
    echo 'esac'; } > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env GITHUB_REPOSITORY="petry-projects/.github-private" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _reusable_differs agent-shield CAND PRIOR"
  [ "$status" -eq 0 ]; [ "$output" = "1" ]
}

@test "_reusable_differs: cross-repo agent — identical host blob → 0" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho "samesamesame"\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env GITHUB_REPOSITORY="petry-projects/.github-private" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _reusable_differs agent-shield CAND PRIOR"
  [ "$status" -eq 0 ]; [ "$output" = "0" ]
}

@test "_reusable_differs: cross-repo agent — unresolvable blob fails CLOSED → 1" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho ""\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env GITHUB_REPOSITORY="petry-projects/.github-private" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _reusable_differs agent-shield CAND PRIOR"
  [ "$status" -eq 0 ]; [ "$output" = "1" ]
}

# ── _run_json: transient-retry vs sustained fail-closed (#738) ─────────────────
# The 4h scheduled tick fans _run_json out across every agent × tier repo under the
# workflow step's `set -euo pipefail`, so a single transient `gh run list` blip used
# to fail the whole fleet sweep. A bounded retry rides out a momentary hiccup; a
# SUSTAINED failure must still fail CLOSED (non-zero) so an empty [] never masks
# real failures and green-lights a bad promotion.
@test "_run_json: retries a transient gh failure, then returns the payload (#738)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails"; echo 2 > "$RJ_FAILS_LEFT"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: transient error" >&2; exit 1; fi
echo '[{"conclusion":"success","createdAt":"2026-01-01T00:00:00Z","databaseId":1,"workflowName":"X"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"conclusion":"success"'* ]]
}

@test "_run_json: fails CLOSED (non-zero) when gh fails on every attempt (#738)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho "gh: down" >&2\nexit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to fetch run list"* ]]
}

# A tier repo that has NEVER run a given agent's workflow is not a fetch failure:
# `gh run list --workflow <name>` exits non-zero with "could not find any workflows
# named <name>". That repo legitimately has zero runs of this workflow, so _run_json
# must return [] immediately — NOT retry and fail CLOSED. Before #747 this indistinct
# non-zero exit exhausted the retries and failed the whole scheduled fleet sweep.
@test "_run_json: workflow-not-present in a tier repo returns [] (no fail-closed) (#747)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "could not find any workflows named Some Workflow" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo 'Some Workflow' ''"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_run_json: workflow-not-present returns immediately without retrying (#747)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls"; export CALL_LOG
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo x >> "$CALL_LOG"
echo "could not find any workflows named Some Workflow" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo 'Some Workflow' ''"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALL_LOG")" -eq 1 ]
  [[ "$output" != *"retrying"* ]]
  [[ "$output" != *"failed to fetch run list"* ]]
}

@test "_run_json: empty CANARY_GH_RETRIES falls back to safe default (3)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails2"; echo 1 > "$RJ_FAILS_LEFT"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: error" >&2; exit 1; fi
echo '[{"conclusion":"success","createdAt":"2026-01-01T00:00:00Z","databaseId":1,"workflowName":"X"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES="" \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"conclusion":"success"'* ]]
}

@test "_run_json: non-integer CANARY_GH_RETRIES falls back to safe default (3)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails3"; echo 1 > "$RJ_FAILS_LEFT"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: error" >&2; exit 1; fi
echo '[{"conclusion":"success","createdAt":"2026-01-01T00:00:00Z","databaseId":1,"workflowName":"X"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES="not-a-number" \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"conclusion":"success"'* ]]
}

@test "_run_json: empty CANARY_GH_RETRY_SLEEP falls back to safe default (2)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho '"'"'[{"conclusion":"success","createdAt":"2026-01-01T00:00:00Z","databaseId":1,"workflowName":"X"}]'"'"'\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/sleep" <<'SEOF'
#!/usr/bin/env bash
case "$1" in ''|*[!0-9]*) echo "bad sleep arg: $1" >&2; exit 1 ;; esac
exit 0
SEOF
  chmod +x "$STUB_BIN/sleep"
  run env CANARY_GH_RETRY_SLEEP="" CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
}

@test "_run_json: non-integer CANARY_GH_RETRY_SLEEP falls back to safe default (2)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho '"'"'[{"conclusion":"success","createdAt":"2026-01-01T00:00:00Z","databaseId":1,"workflowName":"X"}]'"'"'\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/sleep" <<'SEOF'
#!/usr/bin/env bash
case "$1" in ''|*[!0-9]*) echo "bad sleep arg: $1" >&2; exit 1 ;; esac
exit 0
SEOF
  chmod +x "$STUB_BIN/sleep"
  run env CANARY_GH_RETRY_SLEEP="not-a-number" CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
}

@test "_run_json: exponential backoff delay is capped at 30 seconds" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-log"
  cat > "$STUB_BIN/sleep" <<SEOF
#!/usr/bin/env bash
echo "\$1" >> "$SLEEP_LOG"
SEOF
  chmod +x "$STUB_BIN/sleep"
  printf '#!/usr/bin/env bash\necho "gh: down" >&2\nexit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=16 CANARY_GH_RETRIES=5 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''" || true
  while IFS= read -r val; do
    [ "$val" -le 30 ] || { echo "sleep called with $val > 30"; false; }
  done < "$SLEEP_LOG"
}

@test "_run_json: empty repo returns [] without calling gh" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho "gh should not be called" >&2\nexit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run bash -c "source '$ORCH' && _run_json '' some-wf '2026-01-01T00:00:00Z'"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_run_json: wildcard repo returns [] without calling gh" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho "gh should not be called" >&2\nexit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run bash -c "source '$ORCH' && _run_json '*' some-wf '2026-01-01T00:00:00Z'"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ── _run_json: surface the REAL error, not a bare "transient" (#810) ───────────
# The old wrapper swallowed gh's stderr (2>/dev/null) and printed only "transient
# failure … after N attempts", hiding whether a sweep was blocked by a 403
# secondary-rate-limit, a 5xx blip, or bad credentials. The annotations must now
# carry the HTTP status + a coarse class so an operator can tell them apart.
@test "_run_json: final ::error:: surfaces the real HTTP 403 secondary-rate-limit status/class (#810)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh: HTTP 403: You have exceeded a secondary rate limit (https://api.github.com/...)" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to fetch run list"* ]]
  [[ "$output" == *"403"* ]]
  [[ "$output" == *"secondary-rate-limit"* ]]
}

@test "_run_json: retry ::warning:: surfaces the real HTTP status/class before retrying (#810)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails-warn"; echo 1 > "$RJ_FAILS_LEFT"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: HTTP 502 Bad Gateway" >&2; exit 1; fi
echo '[{"conclusion":"success","createdAt":"2026-01-01T00:00:00Z","databaseId":1,"workflowName":"X"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"conclusion":"success"'* ]]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"502"* ]]
  [[ "$output" == *"server-error"* ]]
}

@test "_run_json: an auth failure is classed as auth, not a bare transient (#810)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh: Bad credentials (HTTP 401)" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"auth"* ]]
}

# ── _run_json: honor an explicit Retry-After / x-ratelimit-reset hint (#810) ───
@test "_run_json: honors a Retry-After hint from gh stderr for the backoff delay (#810)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-log-ra"
  cat > "$STUB_BIN/sleep" <<SEOF
#!/usr/bin/env bash
echo "\$1" >> "$SLEEP_LOG"
SEOF
  chmod +x "$STUB_BIN/sleep"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails-ra"; echo 1 > "$RJ_FAILS_LEFT"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: HTTP 403: rate limited, Retry-After: 7" >&2; exit 1; fi
echo '[]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  # base sleep of 1 would give a small exponential delay; the 7s Retry-After must win.
  run env CANARY_GH_RETRY_SLEEP=1 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  grep -qx '7' "$SLEEP_LOG"
}

@test "_run_json: honors uppercase X-RateLimit-Reset header in gh stderr (#810)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-log-rl"
  cat > "$STUB_BIN/sleep" <<SEOF
#!/usr/bin/env bash
echo "\$1" >> "$SLEEP_LOG"
SEOF
  chmod +x "$STUB_BIN/sleep"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails-rl"; echo 1 > "$RJ_FAILS_LEFT"
  # Emit the header in mixed case, as GitHub's real API does.
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: error: X-RateLimit-Reset: 5" >&2; exit 1; fi
echo '[]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=1 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  # The x-ratelimit-reset epoch check may yield a small positive delta; just verify sleep ran.
  [ -s "$SLEEP_LOG" ]
}

@test "_run_json: CANARY_GH_RETRY_AFTER_CAP limits an oversized server hint (#810)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  SLEEP_LOG="$BATS_TEST_TMPDIR/sleep-log-cap"
  cat > "$STUB_BIN/sleep" <<SEOF
#!/usr/bin/env bash
echo "\$1" >> "$SLEEP_LOG"
SEOF
  chmod +x "$STUB_BIN/sleep"
  export RJ_FAILS_LEFT="$BATS_TEST_TMPDIR/rj-fails-cap"; echo 1 > "$RJ_FAILS_LEFT"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
n="$(cat "$RJ_FAILS_LEFT")"
if [ "$n" -gt 0 ]; then echo "$((n - 1))" > "$RJ_FAILS_LEFT"; echo "gh: HTTP 429: rate limited, Retry-After: 9999" >&2; exit 1; fi
echo '[]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=1 CANARY_GH_RETRIES=3 CANARY_GH_RETRY_AFTER_CAP=60 \
    bash -c "source '$ORCH' && _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  # Retry-After=9999 must be capped to 60 by CANARY_GH_RETRY_AFTER_CAP.
  grep -qx '60' "$SLEEP_LOG"
}

# ── _run_json: per-(repo,workflow) cache + not-found-is-empty + local since (#819) ──
# The 4h sweep asks for a workflow's runs once per sample window (candidate / baseline /
# downgrade / correctness). Enumerating per window per workflow tripped secondary rate
# limits, AND a zero-run workflow made `gh run list --workflow` exit non-zero with "could
# not find any workflows named …" — which #810's wrapper retried 6× as a transient, blowing
# a sweep out to ~20 min until the job was cancelled. #819: one UNBOUNDED read per
# (repo,workflow), memoized; the since cut applied locally; a not-found is a cached [].
@test "_run_json: memoizes per (repo,workflow) — two windows share ONE gh call (#819)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/gh-calls"; : > "$CALLS"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "call" >> "$CALLS"
echo '[{"conclusion":"success","createdAt":"2026-01-10T00:00:00Z","databaseId":1,"workflowName":"W"},
       {"conclusion":"failure","createdAt":"2026-01-02T00:00:00Z","databaseId":2,"workflowName":"W"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env _RUNS_CACHE_DIR="$BATS_TEST_TMPDIR/rc" bash -c '
    mkdir -p "$_RUNS_CACHE_DIR"; source "'"$ORCH"'"
    _run_json some/repo W "2026-01-05T00:00:00Z"   # candidate window (since = 01-05)
    _run_json some/repo W ""                          # baseline window (no lower bound)
  '
  [ "$status" -eq 0 ]
  # Both windows served by a single fetch of (some/repo, W).
  [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "_repo_wf_runs_cached: the run limit is part of the cache key — a limit-1000 hit never serves a limit-5000 read (#1224)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/limit-calls"; : > "$CALLS"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
echo '[{"conclusion":"success","createdAt":"2026-01-10T00:00:00Z","databaseId":1,"workflowName":"W"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env _RUNS_CACHE_DIR="$BATS_TEST_TMPDIR/rc-limit" bash -c '
    mkdir -p "$_RUNS_CACHE_DIR"; source "'"$ORCH"'"
    _repo_wf_runs_cached some/repo W 0 1000 >/dev/null
    _repo_wf_runs_cached some/repo W 0 1000 >/dev/null
    _repo_wf_runs_cached some/repo W 0 5000 >/dev/null
  '
  [ "$status" -eq 0 ]
  # Same limit is served from cache (1 fetch); the larger limit is a distinct entry (2nd fetch).
  [ "$(wc -l < "$CALLS")" -eq 2 ]
  grep -q -- "-L 5000" "$CALLS"
}

@test "_run_json: cache key is collision-free — 'A B' vs 'A/B' workflows don't share a file (#835 CodeRabbit)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  # gh echoes back the requested workflow name so we can prove which cache entry served the call.
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
wf=""; prev=""
for a in "$@"; do [ "$prev" = "--workflow" ] && wf="$a"; prev="$a"; done
printf '[{"conclusion":"success","createdAt":"2026-01-10T00:00:00Z","databaseId":1,"workflowName":"%s"}]\n' "$wf"
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env _RUNS_CACHE_DIR="$BATS_TEST_TMPDIR/rc2" bash -c '
    mkdir -p "$_RUNS_CACHE_DIR"; source "'"$ORCH"'"
    _run_json some/repo "A B" "" | jq -r ".[0].workflowName"
    _run_json some/repo "A/B" "" | jq -r ".[0].workflowName"
  '
  [ "$status" -eq 0 ]
  # Under a char-substitution key both names would collapse to "A_B" and the second call
  # would be served the first's cached "A B" row. A hashed key keeps them distinct.
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "A B" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "A/B" ]
}

@test "_run_json: applies the since cut LOCALLY — pre-cut rows excluded, empty since keeps all (#819)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo '[{"conclusion":"success","createdAt":"2026-01-10T00:00:00Z","databaseId":1,"workflowName":"W"},
       {"conclusion":"failure","createdAt":"2026-01-02T00:00:00Z","databaseId":2,"workflowName":"W"}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  # since = 01-05 → only the 01-10 row survives.
  run bash -c "source '$ORCH' && _run_json some/repo W '2026-01-05T00:00:00Z' | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]; [ "$output" = "[1]" ]
  # empty since → both rows.
  run bash -c "source '$ORCH' && _run_json some/repo W '' | jq -c 'map(.databaseId)|sort'"
  [ "$status" -eq 0 ]; [ "$output" = "[1,2]" ]
}

@test "_run_json: fetch is unbounded — passes --workflow but NOT --created (#819)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ARGS="$BATS_TEST_TMPDIR/gh-args"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$ARGS"
echo '[]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash -c "source '$ORCH' && _run_json some/repo 'Dev-Lead Agent' '2026-01-05T00:00:00Z'"
  [ "$status" -eq 0 ]
  grep -q -- '--workflow' "$ARGS"
  ! grep -q -- '--created' "$ARGS"
}

@test "_run_json: a not-found workflow returns [] immediately — no retry, no fail-flag (#819)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/nf-calls"; : > "$CALLS"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "call" >> "$CALLS"
echo "could not find any workflows named Persona — Mention Router" >&2
exit 1
GHEOF
  chmod +x "$STUB_BIN/gh"
  export FLAG="$BATS_TEST_TMPDIR/fetch-fail-flag"; : > "$FLAG"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=6 _CANARY_FETCH_FAIL_FLAG="$FLAG" \
    bash -c "source '$ORCH' && _run_json some/repo 'Persona — Mention Router' ''"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  # Not retried (single gh call) and NOT recorded as a fetch outage (#820 flag empty).
  [ "$(wc -l < "$CALLS")" -eq 1 ]
  [ ! -s "$FLAG" ]
}

@test "_cumulative_health: does not crash when a window fails CLOSED to an empty payload (#819 arith guard)" {
  # A sustained fetch failure makes _run_json return non-zero → json="" in the caller. The
  # `$(( fail + $(jq … <<< "${json:-[]}") ))` guard must count 0, never emit `+  ` (bash
  # arithmetic operand-expected syntax error, the second half of the #803 canary regression).
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho "gh: HTTP 503: server error" >&2\nexit 1\n' > "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  run env CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH' && _cumulative_health dev-lead '' 0 - some/repo"
  # Fail-closed path returns non-zero, but NEVER with an arithmetic syntax error.
  [[ "$output" != *"syntax error"* ]]
  [[ "$output" != *"operand expected"* ]]
}

# ── next_channel_in_order ─────────────────────────────────────────────────────
@test "next_channel_in_order: walks the ring order" {
  [ "$(next_channel_in_order next  'next,ring0,ring1,stable')" = "ring0" ]
  [ "$(next_channel_in_order ring0 'next,ring0,ring1,stable')" = "ring1" ]
  [ "$(next_channel_in_order ring1 'next,ring0,ring1,stable')" = "stable" ]
}
@test "next_channel_in_order: last ring → empty" {
  [ -z "$(next_channel_in_order stable 'next,ring0,ring1,stable')" ]
}

# ── transition_key (source→frontier lookup key) ───────────────────────────────
@test "transition_key: frontier maps to its source→frontier key" {
  [ "$(transition_key ring0 'next,ring0,ring1,stable')" = "next->ring0" ]
  [ "$(transition_key ring1 'next,ring0,ring1,stable')" = "ring0->ring1" ]
  [ "$(transition_key stable 'next,ring0,ring1,stable')" = "ring1->stable" ]
}

# ── pair_verdict (pure per-pair verdict, #1242: #1118 pending rule + #1225 tag-gap hold) ──
# Each ring is one of: RESOLVED (a commit; same or different from the other side), ABSENT
# ("-", unknown=0 — legacy "no tag"), or ERRORED (unknown=1 — the lookup failed, so the
# commit is not known). Full {resolved, absent, errored} × {src, dst} matrix, gh-free.
@test "pair_verdict: resolved src, dst on the same commit → ON_CANDIDATE (nothing pending)" {
  [ "$(pair_verdict aaa 0 aaa 0)" = "ON_CANDIDATE" ]
}
@test "pair_verdict: resolved src, dst on a different commit → PENDING" {
  [ "$(pair_verdict aaa 0 bbb 0)" = "PENDING" ]
}
@test "pair_verdict: resolved src, absent dst → PENDING (dst never received a release)" {
  [ "$(pair_verdict aaa 0 - 0)" = "PENDING" ]
}
@test "pair_verdict: resolved src, errored dst → HOLD_UNKNOWN" {
  [ "$(pair_verdict aaa 0 - 1)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: absent src, resolved dst → UNRESOLVABLE_SOURCE (BLOCKED, never a false COMPLETE)" {
  [ "$(pair_verdict - 0 bbb 0)" = "UNRESOLVABLE_SOURCE" ]
}
@test "pair_verdict: absent src, absent dst → ON_CANDIDATE (legacy: nothing to promote)" {
  [ "$(pair_verdict - 0 - 0)" = "ON_CANDIDATE" ]
}
@test "pair_verdict: absent src, errored dst → HOLD_UNKNOWN" {
  [ "$(pair_verdict - 0 - 1)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: errored src, resolved dst → HOLD_UNKNOWN" {
  [ "$(pair_verdict - 1 bbb 0)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: errored src, absent dst → HOLD_UNKNOWN (an outage is never read as 'on the candidate')" {
  [ "$(pair_verdict - 1 - 0)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: errored src, errored dst → HOLD_UNKNOWN" {
  [ "$(pair_verdict - 1 - 1)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: precedence — an errored side beats a matching commit (HOLD_UNKNOWN over ON_CANDIDATE)" {
  [ "$(pair_verdict aaa 1 aaa 0)" = "HOLD_UNKNOWN" ]
  [ "$(pair_verdict aaa 0 aaa 1)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: precedence — an errored side beats an unresolvable source and a pending pair" {
  [ "$(pair_verdict - 1 bbb 1)" = "HOLD_UNKNOWN" ]
  [ "$(pair_verdict aaa 1 bbb 0)" = "HOLD_UNKNOWN" ]
}
@test "pair_verdict: an empty commit is the absent sentinel '-' (same verdicts as '-')" {
  [ "$(pair_verdict '' 0 '' 0)" = "ON_CANDIDATE" ]
  [ "$(pair_verdict '' 0 bbb 0)" = "UNRESOLVABLE_SOURCE" ]
  [ "$(pair_verdict aaa 0 '' 0)" = "PENDING" ]
  [ "$(pair_verdict '' 0 - 0)" = "ON_CANDIDATE" ]
}
@test "pair_verdict: an omitted/empty unknown flag means known (0)" {
  [ "$(pair_verdict aaa '' aaa '')" = "ON_CANDIDATE" ]
  [ "$(pair_verdict aaa)" = "PENDING" ]
}
@test "pair_verdict: any unknown flag other than 0 fails CLOSED to HOLD_UNKNOWN" {
  [ "$(pair_verdict aaa yes aaa 0)" = "HOLD_UNKNOWN" ]
  [ "$(pair_verdict aaa 0 aaa 2)" = "HOLD_UNKNOWN" ]
}

# _pv_rings <commit:unknown>... — fold pair_verdict over an ordered ring list, echoing one
# "<i> <verdict>" per pair NOT on its candidate, or COMPLETE when none is (the shape
# _frontier_state emits). Test-only glue; the decision itself is pair_verdict's.
_pv_rings() {
  local prev="" ring i=0 v any=0
  for ring in "$@"; do
    if [ -n "$prev" ]; then
      v="$(pair_verdict "${prev%:*}" "${prev##*:}" "${ring%:*}" "${ring##*:}")"
      if [ "$v" != "ON_CANDIDATE" ]; then echo "$i $v"; any=1; fi
      i=$((i + 1))
    fi
    prev="$ring"
  done
  [ "$any" -eq 1 ] || echo "COMPLETE"
}
@test "pair_verdict rings: every ring on one commit → legacy COMPLETE" {
  [ "$(_pv_rings aaa:0 aaa:0 aaa:0 aaa:0)" = "COMPLETE" ]
}
@test "pair_verdict rings: every tag ABSENT → legacy COMPLETE (#1118 AC6, unchanged)" {
  [ "$(_pv_rings -:0 -:0 -:0 -:0)" = "COMPLETE" ]
}
@test "pair_verdict rings: TOTAL tag-lookup outage → every pair HOLD_UNKNOWN, never COMPLETE (#1225)" {
  run _pv_rings -:1 -:1 -:1 -:1
  [ "$status" -eq 0 ]
  [ "$output" = $'0 HOLD_UNKNOWN\n1 HOLD_UNKNOWN\n2 HOLD_UNKNOWN' ]
}
@test "pair_verdict rings: one errored ring holds BOTH pairs touching it; the rest evaluate normally" {
  run _pv_rings ccc:0 bbb:0 -:1 aaa:0
  [ "$status" -eq 0 ]
  [ "$output" = $'0 PENDING\n1 HOLD_UNKNOWN\n2 HOLD_UNKNOWN' ]
}
@test "pair_verdict rings: no tier skipping — each pair compares only adjacent rings" {
  # stable (aaa) differs from next (ccc) but is on ring1's commit: only the lower pairs are pending.
  run _pv_rings ccc:0 bbb:0 aaa:0 aaa:0
  [ "$status" -eq 0 ]
  [ "$output" = $'0 PENDING\n1 PENDING' ]
}
@test "pair_verdict rings: absent source over a populated ring → UNRESOLVABLE_SOURCE, not COMPLETE" {
  run _pv_rings -:0 bbb:0 bbb:0 bbb:0
  [ "$status" -eq 0 ]
  [ "$output" = "0 UNRESOLVABLE_SOURCE" ]
}

# ── canary-rings.json SoT shape (rings + gate knobs) ──────────────────────────
@test "canary-rings.json: pr-auto-review onboarded to canary; unmanaged block emptied" {
  run jq -e '.agents["pr-auto-review"].host == "petry-projects/.github"' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["pr-auto-review"].run_workflow == "PR Auto-Review — Ready Check"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"pr-auto-review\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  # every reusable is now a managed agent — the unmanaged block holds nothing
  run jq -e '(.unmanaged // {}) | length == 0' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: add-to-project onboarded to full ring model (#651)" {
  run jq -e '.agents["add-to-project"].host == "petry-projects/.github"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"add-to-project\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  # moved OUT of the unmanaged block (now a managed ring agent)
  run jq -e '.unmanaged | has("add-to-project") | not' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["add-to-project"] | (has("next_tier_health_signal")|not) and (has("soak_start_ring")|not)' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: feature-ideation onboarded (cross-repo host, standard rings, #614)" {
  run jq -e '.agents["feature-ideation"].host == "petry-projects/.github"' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["feature-ideation"].reusable == ".github/workflows/feature-ideation-reusable.yml"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"feature-ideation\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  run jq -e '.agents["feature-ideation"].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["feature-ideation"] | (has("next_tier_health_signal")|not) and (has("soak_start_ring")|not)' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: ci-failure-analyst onboarded (this-repo host, standard rings, #1159)" {
  run jq -e '.agents["ci-failure-analyst"].host == "petry-projects/.github-private"' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["ci-failure-analyst"].reusable == ".github/workflows/ci-failure-analyst-reusable.yml"' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["ci-failure-analyst"].run_workflow == "CI Failure Analyst"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"ci-failure-analyst\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  # standard #548 gate + organic-traffic model (no synthetic-canary fields)
  run jq -e '.agents["ci-failure-analyst"].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["ci-failure-analyst"] | (has("next_tier_health_signal")|not) and (has("soak_start_ring")|not)' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: pr-review onboarded (cross-repo host, standard rings, grandfathered filename, #1106)" {
  # AC4: cross-repo agent — its reusable lives in .github-private, so releases/tags host there.
  run jq -e '.agents["pr-review"].host == "petry-projects/.github-private"' "$RINGS"
  [ "$status" -eq 0 ]
  # AC4: the reusable is the grandfathered non-`-reusable.yml` engine (petry-projects/.github-private#1127) —
  # exactly why the *-reusable.yml drift scan never caught the gap this issue closes.
  run jq -e '.agents["pr-review"].reusable == ".github/workflows/pr-review.yml"' "$RINGS"
  [ "$status" -eq 0 ]
  # run_workflow is the trigger stub's name (the run history the gate reads), mirroring pr-review-mention.
  run jq -e '.agents["pr-review"].run_workflow == "PR Review Agent — Trigger"' "$RINGS"
  [ "$status" -eq 0 ]
  # AC1: standard 4-ring topology — .github-private self-hosts on next (the v1-next dogfood), fleet on stable.
  run bash -c "jq -r '.agents[\"pr-review\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  # next = the host dogfood ($host); stable = the whole fleet (*)
  run jq -e '.agents["pr-review"].rings[] | select(.channel=="next") | .members == ["$host"]' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["pr-review"].rings[] | select(.channel=="stable") | (.members | index("*")) != null' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["pr-review"].rings[] | select(.channel=="ring1") | (.members|index("petry-projects/TalkTerm")) and (.members|index("petry-projects/bmad-bgreat-suite"))' "$RINGS"
  [ "$status" -eq 0 ]
  # standard #548 gate + organic-traffic model (no synthetic-canary fields)
  run jq -e '.agents["pr-review"].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["pr-review"] | (has("next_tier_health_signal")|not) and (has("soak_start_ring")|not)' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: valid JSON + dev-lead host + ordered rings" {
  run jq -e '.agents["dev-lead"].host == "petry-projects/.github-private"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"dev-lead\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  run jq -e '.agents["dev-lead"].rings[] | select(.channel=="ring1") | (.members | index("petry-projects/TalkTerm")) and (.members | index("petry-projects/bmad-bgreat-suite"))' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: idea->initiative pipeline agents onboarded (standard rings + gate, #1008)" {
  # initiative-planner + idea-triage are host=.github agents with sparse, event-driven
  # traffic. They ride the STANDARD ring model + gate — NO synthetic canary: the empty
  # inner rings waive on dwell (no caller), and ring1->stable soaks until real
  # TalkTerm/bmad traffic (organic or human-triggered) arrives.
  local a
  for a in initiative-planner idea-triage idea-enhancer; do
    run jq -e --arg a "$a" '.agents[$a].host == "petry-projects/.github"' "$RINGS"
    [ "$status" -eq 0 ]
    run bash -c "jq -r --arg a '$a' '.agents[\$a].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
    [ "$output" = "next,ring0,ring1,stable" ]
    # ring1 = the real consumers that gate ring1->stable
    run jq -e --arg a "$a" '.agents[$a].rings[] | select(.channel=="ring1") | (.members|index("petry-projects/TalkTerm")) and (.members|index("petry-projects/bmad-bgreat-suite"))' "$RINGS"
    [ "$status" -eq 0 ]
    # standard #548 gate: inner rings waive, ring1->stable needs >=1 real run
    run jq -e --arg a "$a" '.agents[$a].gate.transitions["next->ring0"].waive_sample_if_no_caller == true and .agents[$a].gate.transitions["ring0->ring1"].waive_sample == true and .agents[$a].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS"
    [ "$status" -eq 0 ]
    # NO synthetic-canary machinery — organic traffic drives the rollout (design decision #1008)
    run jq -e --arg a "$a" '.agents[$a] | (has("next_tier_health_signal")|not) and (has("soak_start_ring")|not)' "$RINGS"
    [ "$status" -eq 0 ]
  done
  # run_workflow names = what the gate samples on the ring tiers
  run jq -e '.agents["initiative-planner"].run_workflow | startswith("Initiative Planner")' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["idea-triage"].run_workflow | startswith("Idea Triage")' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: gate block carries #548 per-transition defaults" {
  # baseline window + spike cap
  run jq -e '.agents["dev-lead"].gate.baseline_window_days == 14' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.baseline_spike_cap_multiple == 3' "$RINGS"
  [ "$status" -eq 0 ]
  # next->ring0: 4h dwell, 0.25 fraction, clamp [3,15], dwell-only when source has no caller
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].dwell_hours == 4' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].sample_fraction_permille == 250' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].sample_clamp_min == 3 and .agents["dev-lead"].gate.transitions["next->ring0"].sample_clamp_max == 15' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["next->ring0"].waive_sample_if_no_caller == true' "$RINGS"
  [ "$status" -eq 0 ]
  # ring0->ring1: 8h dwell, sample waived (cumulative-only)
  run jq -e '.agents["dev-lead"].gate.transitions["ring0->ring1"].dwell_hours == 8' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["ring0->ring1"].waive_sample == true' "$RINGS"
  [ "$status" -eq 0 ]
  # ring1->stable: 12h dwell, >=1 ring1 run
  run jq -e '.agents["dev-lead"].gate.transitions["ring1->stable"].dwell_hours == 12' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.transitions["ring1->stable"].sample_min == 1' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── orchestrator: resolve_members (host-relative tokens) ──────────────────────
@test "orchestrator: resolve_members expands \$host / \$org_infra / * " {
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead next"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github-private" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring0"
  [ "$status" -eq 0 ]; [ "$output" = "petry-projects/.github" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring1"
  [[ "$output" == *"petry-projects/TalkTerm"* ]]
  [[ "$output" == *"petry-projects/bmad-bgreat-suite"* ]]
}

# ── orchestrator: evaluate / promote (read-only + dry-run) with stubs ─────────
_make_stub_bin() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  # dev-lead is cross-repo (host=.github-private, THIS_REPO=.github): channel tags resolve
  # via gh api on the host — the git stub is a no-op; the default gh stub (added by each test)
  # must include git/ref/tags/dev-lead/* cases for channel commits to resolve correctly.
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
}

teardown() { [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; return 0; }

@test "orchestrator: evaluate prints a per-ring gate report and exits 0 (read-only)" {
  _make_stub_bin
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"

  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"next"* ]]
  [[ "$output" == *"stable"* ]]
}

@test "orchestrator: promote --override --dry-run shows the move but never pushes" {
  _make_stub_bin
  # dev-lead is cross-repo (host=.github-private): channel tags resolve via gh api;
  # the dry-run output must show the API PATCH, never a local `git tag -f`/`git push` (#1076).
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  local pushlog="$STUB_BIN/push.log"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"push"*) echo "\$*" >> "$pushlog" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"

  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --override --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$pushlog" ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"ring1"* ]]
  [[ "$output" == *"gh api PATCH"* ]]
  [[ "$output" != *"git tag -f"* ]]
}

@test "orchestrator: no local git tag/push in the promote/rollback move paths — gh api only (#1076)" {
  # Structural guard: the channel-tag move for EVERY agent (this-repo and cross-repo) goes
  # through gh api so the release-manager App's ruleset bypass is applied; a local force-push
  # is not a bypass actor for a tag UPDATE and 013s on protected tags such as dev-lead/next.
  ! grep -Ev '^[[:space:]]*#' "$ORCH" | grep -Eq '\bgit[[:space:]]+(tag|push)\b'
}

# ── orchestrator: full graduated verdicts (cut date + gh run data → gate state) ─
# Lay out next = candidate (cccc); ring0/ring1/stable = prior (bbbb): frontier = ring0,
# transition next->ring0, source = next. The release tag cccc is dated `cut_days` ago,
# so the per-candidate window (and the robust sample target) are exercised end to end.
# dev-lead is cross-repo (host=.github-private, THIS_REPO=.github): channel tags, release
# date, and reusable blobs all resolve via gh api on the host — the git stub is a no-op.
_graduated_stub() {
  local cut_days="$1" run_days_ago="$2" conclusion="$3" reusable_diff="$4"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso cand_blob="reuseAAAA" prior_blob="reuseAAAA"
  [ "$reusable_diff" = "1" ] && prior_blob="reuseBBBB"
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "$cand_blob" ;;
  *"ref=bbbb"*) echo "$prior_blob" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api above
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: PROMOTE verdict — dwell + sample met on a clean per-candidate window" {
  # cut 3 days ago, runs 2 days ago, all success → dwell ≫ 4h, sample 20 ≥ target, clean.
  _graduated_stub 3 2 success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"PROMOTE"* ]]
  [[ "$output" == *"decision for next ring 'ring0'"* ]]
}

@test "orchestrator: BLOCKED + REGRESSION — in-window failure with a changed reusable" {
  # A failure since the candidate cut, and the reusable differs from the prior channel
  # → cumulative-health breach classified as a candidate regression (HALT + rollback).
  _graduated_stub 3 2 failure 1
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

@test "orchestrator: BLOCKED + PRE_EXISTING — in-window failure but reusable unchanged" {
  # Same failure, but the reusable is byte-identical to the prior channel → pre-existing,
  # report only (do NOT rollback, do NOT advance).
  _graduated_stub 3 2 failure 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
}

# ── benign_match (per-reusable known-benign failure-class matcher, #1025 P2) ────
# args: <workflow_name> <failure_signature> <workflow_regex> <step_regex>
@test "benign_match: workflow + step signature both match → yes" {
  [ "$(benign_match 'Dev-Lead Agent' 'Push fix-review branch' 'Dev-Lead' '[Pp]ush')" = "yes" ]
}
@test "benign_match: workflow regex mismatch → no" {
  [ "$(benign_match 'Other Workflow' 'Push branch' 'Dev-Lead' '[Pp]ush')" = "no" ]
}
@test "benign_match: signature does not match step regex → no" {
  [ "$(benign_match 'Dev-Lead Agent' 'Compile sources' 'Dev-Lead' '[Pp]ush')" = "no" ]
}
@test "benign_match: empty step regex never matches (guards against a match-all entry)" {
  [ "$(benign_match 'Dev-Lead Agent' 'anything at all' 'Dev-Lead' '')" = "no" ]
}
@test "benign_match: empty workflow regex matches any workflow" {
  [ "$(benign_match 'Whatever' 'Resolve Dependabot dispatch context' '' '[Dd]ependabot')" = "yes" ]
}

# ── canary-rings.json: benign allowlist + control block shape (#1025 P2) ────────
@test "canary-rings.json: dev-lead gate carries a benign_failure_classes allowlist + control block" {
  run jq -e '.agents["dev-lead"].gate.benign_failure_classes | type == "array" and length >= 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.benign_failure_classes | all(has("id") and has("reason") and has("step"))' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.control | has("allow_pre_existing")' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── orchestrator: evaluate-all iterates the whole registry (#1025 P1) ──────────
@test "orchestrator: evaluate-all iterates every agent in the registry (fleet-wide)" {
  _make_stub_bin
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # A registry with a second (cloned) agent proves fleet iteration over the registry
  # keys rather than a dev-lead hardcode.
  local multi="$BATS_TEST_TMPDIR/rings.json"
  jq '.agents["fleet-canary-test"] = .agents["dev-lead"]' "$RINGS" > "$multi"
  run env CANARY_RINGS="$multi" bash "$ORCH" evaluate-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"fleet-canary-test"* ]]
}

# ── orchestrator: benign-failure allowlist excludes known-benign from cum_fail ──
# Lay out next = candidate (cccc); ring0/ring1/stable = prior (bbbb). Every tier repo
# returns `failure` runs whose only failed step is <step>; `gh run view` yields that
# step so the orchestrator can build a signature and test it against the allowlist.
_benign_stub() {
  local cut_days="$1" run_days_ago="$2" step="$3" reusable_diff="$4"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso cand_blob="reuseAAAA" prior_blob="reuseAAAA"
  [ "$reusable_diff" = "1" ] && prior_blob="reuseBBBB"
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  # dev-lead is cross-repo (host=.github-private, THIS_REPO=.github): channel tags, release
  # date, and reusable blobs all resolve via gh api; run-list/run-view feed the benign check.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "$cand_blob" ;;
  *"ref=bbbb"*) echo "$prior_blob" ;;
  *"run list"*) jq -nc --arg d "$run_iso" '[range(3)|{conclusion:"failure",createdAt:\$d,databaseId:(1000+.),workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) jq -nc --arg s "$step" '{jobs:[{steps:[{name:\$s,conclusion:"failure"}]}]}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api above
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: allowlisted benign failure (reusable unchanged) is excluded from cum_fail → not BLOCKED" {
  # A git-push-permission failure since cut, but the reusable is byte-identical to the
  # prior channel → matches the [Pp]ush benign class → excluded → gate is not BLOCKED.
  _benign_stub 3 2 "Push fix-review branch" 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" != *"BLOCKED"* ]]
  [[ "$output" == *"benign"* ]]
}

@test "orchestrator: benign allowlist is DISABLED when the candidate changed the reusable → BLOCKED+REGRESSION" {
  # Same push failure + matching class, but the candidate changed the reusable → the
  # allowlist must NOT mask a possible candidate regression.
  _benign_stub 3 2 "Push fix-review branch" 1
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

@test "orchestrator: a non-allowlisted failure (reusable unchanged) still BLOCKS as PRE_EXISTING" {
  # Failed step matches no benign class → counted → BLOCKED, triaged PRE_EXISTING.
  _benign_stub 3 2 "Compile TypeScript" 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
}

# ── orchestrator: failures from runs still on the OLD release don't block (#1176) ──
# next = candidate (cccc), every ring = prior (bbbb); all tier repos return 3 failed runs.
# `gh run view --log` prints the resolved "Uses: …@refs/tags/<chan> (<sha>)" line, with <sha>
# = $1 (the release the run actually executed); "none" prints a log with no Uses: line.
_executed_sha_stub() {
  local executed="$1" conclusion="${2:-failure}" fail_sub="${3:-repo petry-projects/TalkTerm --workflow}" cut_iso run_iso
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cut_iso="$(date -u -d "-3 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-3d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-2 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-2d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseAAAA" ;;
  *"run list"*)
    # Only <fail_sub> (default: TalkTerm, a ring1 member = the DESTINATION side of next->ring0)
    # fails; every other repo is green — mirrors #1176's real case.
    __c=success; case "\$*" in *"$fail_sub"*) __c="$conclusion" ;; esac
    jq -nc --arg d "$run_iso" --arg c "\$__c" '[range(3)|{conclusion:\$c,createdAt:\$d,databaseId:(1000+.),workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*"--log"*)
    # Mirrors real \`gh run view --log\` output: "<job><TAB><step><TAB><timestamp> <text>".
    ts="2026-09-25T00:00:00.1234567Z"
    U="Uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@refs/tags/dev-lead/v2-ring1"
    if [ "$executed" = logfail ]; then exit 1
    elif [ "$executed" = none ]; then printf 'build\tUNKNOWN STEP\t%s nothing relevant\n' "\$ts"
    elif [ "$executed" = collision ]; then printf 'build\tUNKNOWN STEP\t%s Uses: someone/else/.github/workflows/dev-lead-reusable.yml@refs/tags/x (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n' "\$ts"
    elif [ "$executed" = forgedcand ]; then
      # genuine OLD line first, then the same job echoes a forged CANDIDATE-sha line
      printf 'build\tUNKNOWN STEP\t%s %s (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n' "\$ts" "\$U"
      printf 'build\tUNKNOWN STEP\t%s %s (cccccccccccccccccccccccccccccccccccccccc)\n' "\$ts" "\$U"
    elif [ "$executed" = forged ]; then
      # genuine candidate line first, then the same job echoes a forged OLD-sha line
      printf 'build\tUNKNOWN STEP\t%s %s (cccccccccccccccccccccccccccccccccccccccc)\n' "\$ts" "\$U"
      printf 'build\tUNKNOWN STEP\t%s %s (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n' "\$ts" "\$U"
    else
      n=0; for sha in $executed; do n=\$((n+1)); printf 'job%s\tUNKNOWN STEP\t%s %s (%s)\n' "\$n" "\$ts" "\$U" "\$sha"; done
    fi ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Compile TypeScript","conclusion":"failure"}]}]}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
:
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: failures from runs on the OLD release do not block the candidate (#1176)" {
  _executed_sha_stub bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" != *"BLOCKED"* ]]
  [[ "$output" == *"target-ring health"* ]]
  [[ "$output" == *"informational"* ]]
}

@test "orchestrator: failures from runs that executed the candidate SHA still BLOCK (#1176)" {
  _executed_sha_stub cccccccccccccccccccccccccccccccccccccccc
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" != *"target-ring health"* ]]
}

@test "orchestrator: a run that called the reusable at the old AND candidate SHA still BLOCKS (#1176)" {
  _executed_sha_stub "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "orchestrator: a Uses: line for a different host's same-named workflow is not attributed — BLOCKS (#1176)" {
  _executed_sha_stub collision
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "orchestrator: a forged old-SHA Uses: line echoed after the genuine one is ignored — still BLOCKS (#1176)" {
  _executed_sha_stub forged
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "orchestrator: only the FIRST Uses: line per job is trusted — a later forged candidate-SHA line cannot re-block an old-release run (#1176)" {
  _executed_sha_stub forgedcand
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" != *"BLOCKED"* ]]
  [[ "$output" == *"target-ring health"* ]]
}

@test "orchestrator: old-release failures on the SOURCE tier still BLOCK — attribution only applies to tiers not yet on the candidate (#1176)" {
  # The source tier's sample still counts runs from before the candidate reached it, so dropping only
  # their failures would let a candidate with no executions there reach PROMOTE. The host (.github-private)
  # is the source tier of next->ring0 and its failing run's log names the OLD sha: it must still count.
  _executed_sha_stub bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb failure "repo petry-projects/.github-private --workflow"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" != *"target-ring health"* ]]
}

@test "orchestrator: a short (7-char) candidate SHA in the Uses: line is matched by prefix and BLOCKS (#1176)" {
  _executed_sha_stub ccccccc
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "orchestrator: a failing 'gh run view --log' lookup fails closed and BLOCKS (#1176)" {
  _executed_sha_stub logfail
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "orchestrator: startup_failure runs are never attributed to an old release — they still BLOCK (#1176)" {
  _executed_sha_stub bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb startup_failure
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "orchestrator: a failure whose executed release cannot be determined fails closed and BLOCKS (#1176)" {
  _executed_sha_stub none
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

# ── orchestrator: promote --allow-pre-existing (control override, #1025 P2) ─────
@test "orchestrator: promote --allow-pre-existing advances a BLOCKED+PRE_EXISTING frontier (dry-run)" {
  _graduated_stub 3 2 failure 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --allow-pre-existing --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
  [[ "$output" != *"not promoting"* ]]
}

@test "orchestrator: promote --allow-pre-existing REFUSES a BLOCKED+REGRESSION frontier" {
  _graduated_stub 3 2 failure 1
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --allow-pre-existing --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRY-RUN"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

# ── orchestrator: cross-repo agents resolve tags on `host`, not the local checkout ─
# (#1049) A cross-repo agent (host = petry-projects/.github) keeps its <name>/<channel>
# and <name>/vX.Y.Z tags on the HOST repo, not this checkout. `evaluate` must resolve them
# there via `gh api` (dereferencing annotated tags) — reading the LOCAL refs makes every
# ring resolve empty → "all rings equal → fully rolled out", which would falsely SKIP a
# cross-repo agent that is actually ring1 with stable on an old baseline (READY to promote).
_crossrepo_stub() {
  # next=ring0=ring1 on the candidate (cccc); stable on the OLD baseline (bbbb):
  # frontier = stable, transition = ring1->stable — the ring1->stable promotion is pending.
  # auto-rebase is a this-repo agent (host=.github == THIS_REPO): channel tags and release
  # date resolve via local git; gh handles run-list only.
  local cut_days="$1" run_days_ago="$2" conclusion="$3"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cand="cccccccccccccccccccccccccccccccccccccccc"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  # gh: run-list only — channel/release tag resolution is handled by git below.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # git: auto-rebase is this-repo — channel tags and the release tag date live in the local
  # checkout. The for-each-ref simulates an ANNOTATED release tag (refname|obj|*obj|creatordate)
  # dereferencing to the candidate commit, so candidate_cut_date resolves its tagger date (#1046).
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) printf 'refs/tags/auto-rebase/v2.0.0|tagobj|%s|%s\n' "$cand" "$cut_iso" ;;
  *"rev-parse"*"auto-rebase/next"*)   echo "$cand" ;;
  *"rev-parse"*"auto-rebase/ring0"*)  echo "$cand" ;;
  *"rev-parse"*"auto-rebase/ring1"*)  echo "$cand" ;;
  *"rev-parse"*"auto-rebase/stable"*) echo "$old" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: cross-repo agent resolves channel+release tags on host → ring1->stable pending, NOT 'fully rolled out' (#1049)" {
  # cut 2 days ago (dwell ≫ 12h), ring1 runs 1 day ago all success → sample ≥ 1, clean.
  _crossrepo_stub 2 1 success
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate auto-rebase
  [ "$status" -eq 0 ]
  [[ "$output" != *"fully rolled out"* ]]
  [[ "$output" == *"ring1->stable"* ]]
  [[ "$output" == *"PROMOTE"* ]]
}

# ── orchestrator: promote-all — the gated fleet auto-promote (the SCHEDULED arm, #1045b) ─
@test "orchestrator: promote-all iterates every registry agent and forwards to promote (dry-run, no push)" {
  _make_stub_bin
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  local pushlog="$STUB_BIN/push.log"
  # Reuse the dev-lead git stub but log any push so we can assert the sweep never mutates.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) : ;;
  *"push"*) echo "\$*" >> "$pushlog" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"

  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote-all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"promote-all: fleet-wide"* ]]
  # Every registry agent gets its own section (the loop covers the whole fleet, not dev-lead only).
  [[ "$output" == *"agent: dev-lead"* ]]
  [[ "$output" == *"agent: auto-rebase"* ]]
  [[ "$output" == *"agent: pr-review-mention"* ]]
  # A real move is never pushed under --dry-run.
  [ ! -f "$pushlog" ]
}

# ── orchestrator: cross-repo promote MOVES the channel tag on the HOST via gh api (#1054) ─
# A cross-repo agent (host = petry-projects/.github) keeps its channel tags on the host, so
# the promote move must go through `gh api PATCH .../git/refs/tags/...`, NOT local `git tag -f`
# (which fails "nonexistent object" for a host commit absent from this checkout — #1054).
@test "orchestrator: cross-repo promote --dry-run shows the host gh-api move, not a local git tag (#1054)" {
  _crossrepo_stub 2 1 success   # auto-rebase ring1->stable PROMOTE
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote auto-rebase --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"gh api PATCH repos/petry-projects/.github/git/refs/tags/auto-rebase/stable"* ]]
  [[ "$output" != *"git tag -f"* ]]
}

_crossrepo_promote_stub() {
  # Like _crossrepo_stub but the gh stub LOGS any ref mutation (PATCH/POST) to $MOVE_LOG so
  # a REAL promote can be asserted to move the tag via gh api (never via local git tag/push).
  # auto-rebase is this-repo (host=.github == THIS_REPO): channel tags resolve via git;
  # all tag WRITES still go through gh api (_gh_move_tag applies to all agents, #1076).
  local cut_days="$1" run_days_ago="$2" conclusion="$3"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export MOVE_LOG="$STUB_BIN/move.log"
  local cand="cccccccccccccccccccccccccccccccccccccccc"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"-X POST"*"git/refs"*)        echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # git: channel tags and release date resolve locally (this-repo); any local tag/push attempt
  # (which should never happen — all writes go via gh api) is recorded for the regression guard.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) printf 'refs/tags/auto-rebase/v2.0.0|tagobj|%s|%s\n' "$cand" "$cut_iso" ;;
  *"rev-parse"*"auto-rebase/next"*)   echo "$cand" ;;
  *"rev-parse"*"auto-rebase/ring0"*)  echo "$cand" ;;
  *"rev-parse"*"auto-rebase/ring1"*)  echo "$cand" ;;
  *"rev-parse"*"auto-rebase/stable"*) echo "$old" ;;
  *"tag -f"*|*"push"*) echo "LOCAL:\$*" >> "$MOVE_LOG" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: cross-repo promote (real) moves the host channel tag via gh api + records the output (#1054)" {
  _crossrepo_promote_stub 2 1 success   # auto-rebase ring1->stable PROMOTE
  local out="$BATS_TEST_TMPDIR/gh_output"; : > "$out"
  local plog="$BATS_TEST_TMPDIR/promotions.tsv"; : > "$plog"
  run env CANARY_RINGS="$RINGS" GITHUB_OUTPUT="$out" CANARY_PROMOTIONS_LOG="$plog" bash "$ORCH" promote auto-rebase
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted auto-rebase/stable"* ]]
  # The move went through gh api PATCH on the HOST, never local git tag/push.
  grep -q "PATCH repos/petry-projects/.github/git/refs/tags/auto-rebase/stable" "$MOVE_LOG"
  ! grep -q "^LOCAL:" "$MOVE_LOG"
  # The move is exposed for the workflow's GitHub Deployment step (#502).
  grep -q "promoted_agent=auto-rebase" "$out"
  grep -q "promoted_ring=stable" "$out"
  # promoted_host is the OWNING repo (the cross-repo host), so the deployment is created
  # where the moved commit exists — not GITHUB_REPOSITORY, which would 422 "No ref found" (#1059).
  grep -q "promoted_host=petry-projects/.github" "$out"
  # The promotions log gets one TSV line per move (agent, ring, sha, owning-repo) so a
  # promote-all run can record a deployment for EVERY promotion, not just the last.
  grep -qP "^auto-rebase\tstable\t[0-9a-f]+\tpetry-projects/\.github$" "$plog"
}

@test "orchestrator: cross-repo promote --dry-run shows the host move but touches neither git nor the API (#1054)" {
  _crossrepo_promote_stub 2 1 success
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote auto-rebase --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"auto-rebase/stable"* ]]
  [[ "$output" == *"petry-projects/.github"* ]]
  [ ! -f "$MOVE_LOG" ]
}

# ── promote: a FAILED tag write is persisted, distinct from a gate-block (#1023 defect 2) ─
@test "orchestrator: a failed promote tag-write is persisted to the failure log (agent/ring/cand/host/reason) (#1023)" {
  _crossrepo_promote_stub 2 1 success   # auto-rebase ring1->stable PROMOTE
  # Make the tag-write PATCH FAIL with a non-404 ruleset rejection (never a gate decision).
  sed 's#\*"-X PATCH"\*"git/refs/tags/"\*).*#*"-X PATCH"*"git/refs/tags/"*) echo "gh: blocked by ruleset release-channel-tags (HTTP 422)" >\&2; exit 1 ;;#' \
    "$STUB_BIN/gh" > "$STUB_BIN/gh.tmp" && mv "$STUB_BIN/gh.tmp" "$STUB_BIN/gh" && chmod +x "$STUB_BIN/gh"
  local flog="$BATS_TEST_TMPDIR/promotions-failed.tsv"; : > "$flog"
  run env CANARY_RINGS="$RINGS" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" promote auto-rebase
  [ "$status" -eq 1 ]                                   # the failed write surfaces as a non-zero run
  [[ "$output" == *"::error::failed to move"* ]]
  # One failure-log line: agent, ring, candidate sha, owning host, and a reason (5 columns).
  grep -qP "^auto-rebase\tstable\t[0-9a-f]+\tpetry-projects/\.github\t.+" "$flog"
}

@test "orchestrator: a gate-BLOCKED promotion writes NOTHING to the failure log (#1023)" {
  # A REGRESSION-blocked frontier holds BEFORE the move — it is expected, tracked by canary-blocker,
  # and must never be conflated with an (unexpected) tag-write failure.
  _graduated_stub 3 2 failure 1                          # BLOCKED + REGRESSION
  local flog="$BATS_TEST_TMPDIR/promotions-failed.tsv"; : > "$flog"
  run env CANARY_RINGS="$RINGS" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" promote dev-lead
  [ "$status" -eq 0 ]                                    # gate-block is not a run failure
  [[ "$output" == *"BLOCKED"* ]]
  [ ! -s "$flog" ]                                       # nothing persisted as a tag-write failure
}

# ── _gh_move_tag: surface the underlying API error, don't swallow it (#743) ─────
# A promotion-due run was failing with only a generic caller-side "failed to move" because
# BOTH gh api calls discarded stderr (`>/dev/null 2>&1`). The mover must now echo the real
# API rejection (::error::) on failure, and only fall back to the POST create-ref path for a
# GENUINE 404/"not found" — a non-404 rejection must not be masked by the POST then 422-ing
# "Reference already exists".
_move_tag_stub() {
  # $1 = PATCH behavior: ok | reject (non-404 422) | absent (404 not found)
  # $2 = POST  behavior: ok | reject   (only reached on the 404 fallback path)
  local patch="$1" post="${2:-ok}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CALL_LOG="$STUB_BIN/calls.log"; : > "$CALL_LOG"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*"git/refs/tags/"*)
    echo "PATCH" >> "$CALL_LOG"
    case "$patch" in
      ok)     echo '{"ref":"refs/tags/x"}'; exit 0 ;;
      reject) echo "gh: Tag agent-shield/v2-ring0 update was blocked by ruleset release-channel-tags (HTTP 422)" >&2; exit 1 ;;
      absent) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      noref)  echo "gh: Reference does not exist (HTTP 422)" >&2; exit 1 ;;
    esac ;;
  *"-X POST"*"git/refs"*)
    echo "POST" >> "$CALL_LOG"
    case "$post" in
      ok)     echo '{"ref":"refs/tags/x"}'; exit 0 ;;
      reject) echo "gh: Validation Failed: sha is not a valid commit (HTTP 422)" >&2; exit 1 ;;
    esac ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "_gh_move_tag: surfaces the API rejection and does NOT fall back to POST on a non-404 PATCH failure (#743)" {
  _move_tag_stub reject
  run bash -c "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"blocked by ruleset release-channel-tags"* ]]
  grep -q '^PATCH$' "$CALL_LOG"
  ! grep -q '^POST$' "$CALL_LOG"
}

@test "_gh_move_tag: a successful PATCH moves the tag and never falls back to POST (#743)" {
  _move_tag_stub ok
  run bash -c "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -eq 0 ]
  grep -q '^PATCH$' "$CALL_LOG"
  ! grep -q '^POST$' "$CALL_LOG"
  [[ "$output" != *"::error::"* ]]
}

@test "_gh_move_tag: falls back to POST (create) when the ref is genuinely absent (404) (#743)" {
  _move_tag_stub absent ok
  run bash -c "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -eq 0 ]
  grep -q '^PATCH$' "$CALL_LOG"
  grep -q '^POST$' "$CALL_LOG"
}

@test "_gh_move_tag: surfaces the create error when the 404 POST fallback also fails (#743)" {
  _move_tag_stub absent reject
  run bash -c "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"Validation Failed"* ]]
}

# ── #745: protected channel-tag WRITES go through a repo-scoped write token ──────
# The owner-wide App token is refused a release-channel-tags ruleset bypass on a PATCH
# of a protected channel tag (403 "Resource not accessible by integration") — GitHub
# evaluates an App's bypass/effective-perms differently for an owner-level token than a
# repo-scoped installation token. The fix mints a SECOND, repo-scoped token
# (Contents:write on the tag hosts) and routes ONLY the tag writes through it via
# CANARY_WRITE_TOKEN — the read-only fleet gate keeps the owner-wide GH_TOKEN so the
# '*' stable-tier enumeration is not regressed. Each stub line records which token was
# in effect (the GH_TOKEN visible to the `gh` child) for the mutation.
_token_capture_stub() {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export TOKEN_LOG="$STUB_BIN/tokens.log"; : > "$TOKEN_LOG"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$*" "${GH_TOKEN:-<unset>}" >> "$TOKEN_LOG"
echo "1111111111111111111111111111111111111111"
exit 0
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "_gh_move_tag: routes the PATCH through CANARY_WRITE_TOKEN when set (#745)" {
  _token_capture_stub
  run env GH_TOKEN=owner-wide CANARY_WRITE_TOKEN=repo-scoped bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -eq 0 ]
  grep -q 'PATCH.*repo-scoped' "$TOKEN_LOG"
  ! grep -q 'PATCH.*owner-wide' "$TOKEN_LOG"
}

@test "_gh_move_tag: falls back to the ambient GH_TOKEN when CANARY_WRITE_TOKEN is unset (#745)" {
  _token_capture_stub
  run env -u CANARY_WRITE_TOKEN GH_TOKEN=owner-wide bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -eq 0 ]
  grep -q 'PATCH.*owner-wide' "$TOKEN_LOG"
}

@test "_gh_create_annotated_tag: routes the object create + ref publish through CANARY_WRITE_TOKEN when set (#745)" {
  _token_capture_stub
  run env GH_TOKEN=owner-wide CANARY_WRITE_TOKEN=repo-scoped bash -c \
    "source '$ORCH' && _gh_create_annotated_tag petry-projects/.github agent-shield/v2.0.0 12b0075a9c48000000000000000000000000000 'agent-shield release v2.0.0'"
  [ "$status" -eq 0 ]
  # both the git/tags object create and the git/refs publish must carry the write token
  [ "$(grep -c 'repo-scoped' "$TOKEN_LOG")" -ge 2 ]
  ! grep -q 'owner-wide' "$TOKEN_LOG"
}

# ── #749: one-shot effective-permission diagnostic on a 403 tag-move ────────────
# #745/#746 (repo-scoped write token) did NOT resolve the 403 "Resource not accessible by
# integration" on a protected channel-tag PATCH. To decide the next step from DATA rather than
# guessing again, the _gh_move_tag 403 failure path (behind #744's un-suppressed error) dumps
# the write token's EFFECTIVE permissions + scope — using the SAME write token the PATCH used —
# so we can tell (a) a token that LACKS effective contents:write (a minting bug, code-fixable)
# from (b) a token that HAS it but is still blocked because the ruleset bypass lapsed (NOT a
# code bug). The diagnostic must run ONLY on a 403 (not on the #743 non-404 422 rejection),
# must still surface the ::error:: + return non-zero, and must not fall back to POST.
_diag_403_stub() {
  local scope="${1:-selected}"   # selected (repo-scoped, low count) | all (owner-wide, high count)
  local install_count
  if [ "$scope" = all ]; then install_count=50; else install_count=2; fi
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CALL_LOG="$STUB_BIN/calls.log"; : > "$CALL_LOG"
  export TOKEN_LOG="$STUB_BIN/tokens.log"; : > "$TOKEN_LOG"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$TOKEN_LOG"
case "\$*" in
  *"-X PATCH"*"git/refs/tags/"*)
    echo "PATCH" >> "$CALL_LOG"
    echo '{"message":"Resource not accessible by integration","status":"403"}' >&2
    exit 1 ;;
  *"-X POST"*"git/refs"*)
    echo "POST" >> "$CALL_LOG"; echo '{"ref":"refs/tags/x"}'; exit 0 ;;
  *"-i "*"repos/"*)
    echo "DIAG_HEADERS" >> "$CALL_LOG"
    printf 'HTTP/2.0 403 Forbidden\r\n'
    printf 'X-Accepted-GitHub-Permissions: contents=write; contents=read\r\n'
    printf '\r\n'
    echo '{"full_name":"petry-projects/.github"}'
    exit 0 ;;
  *"installation/repositories"*)
    echo "DIAG_INSTALL" >> "$CALL_LOG"
    echo '{"total_count":$install_count}'
    exit 0 ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "_gh_move_tag: on a 403 dumps the effective-permission diagnostic then surfaces the error (#749)" {
  _diag_403_stub selected
  run env GH_TOKEN=owner-wide CANARY_WRITE_TOKEN=repo-scoped bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"effective-permission diagnostic"* ]]
  [[ "$output" == *"X-Accepted-GitHub-Permissions: contents=write"* ]]
  [[ "$output" == *"total_count=2"* ]]
  [[ "$output" == *"::error::"* ]]
  grep -q '^PATCH$' "$CALL_LOG"
  grep -q '^DIAG_HEADERS$' "$CALL_LOG"
  grep -q '^DIAG_INSTALL$' "$CALL_LOG"
  ! grep -q '^POST$' "$CALL_LOG"
}

@test "_gh_move_tag: the 403 diagnostic introspects through CANARY_WRITE_TOKEN (#749)" {
  _diag_403_stub selected
  run env GH_TOKEN=owner-wide CANARY_WRITE_TOKEN=repo-scoped bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  grep -q 'installation/repositories.*repo-scoped' "$TOKEN_LOG"
  ! grep -q 'installation/repositories.*owner-wide' "$TOKEN_LOG"
}

@test "_gh_move_tag: the 403 diagnostic reports the higher total_count for an owner-wide installation token (#749)" {
  _diag_403_stub all
  run env GH_TOKEN=owner-wide CANARY_WRITE_TOKEN=repo-scoped bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [[ "$output" == *"total_count=50"* ]]
  [[ "$output" != *"total_count=2"* ]]
}

@test "_gh_move_tag: a non-403 (422 ruleset) failure does NOT trigger the 403 diagnostic (#749)" {
  _move_tag_stub reject
  run bash -c "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" != *"effective-permission diagnostic"* ]]
  [[ "$output" == *"::error::"* ]]
}

@test "_gh_403_diag: empty installation/repositories response does not cause a jq parse error (#749)" {
  # Stub: PATCH → 403; installation/repositories → empty (API failure)
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"-X PATCH"*"git/refs/tags/"*)
    echo '{"message":"Resource not accessible by integration","status":"403"}' >&2; exit 1 ;;
  *"-i "*"repos/"*)
    printf 'HTTP/2.0 403 Forbidden\r\nX-Accepted-GitHub-Permissions: contents=write\r\n\r\n{}'
    exit 0 ;;
  *"installation/repositories"*) exit 1 ;;   # API failure → empty $inst
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env GH_TOKEN=tok bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"effective-permission diagnostic"* ]]
  # Must not print a jq error about parse failure
  [[ "$output" != *"parse error"* ]]
  [[ "$output" == *"total_count=<unreadable>"* ]]
}

@test "_gh_403_diag: installation/repositories response missing keys does not error (#749)" {
  # Stub: installation/repositories returns valid JSON but without the expected keys
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"-X PATCH"*"git/refs/tags/"*)
    echo '{"message":"Resource not accessible by integration","status":"403"}' >&2; exit 1 ;;
  *"-i "*"repos/"*)
    printf 'HTTP/2.0 403 Forbidden\r\nX-Accepted-GitHub-Permissions: contents=write\r\n\r\n{}'
    exit 0 ;;
  *"installation/repositories"*) echo '{}' ;;   # valid JSON but no total_count
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env GH_TOKEN=tok bash -c \
    "source '$ORCH' && _gh_move_tag petry-projects/.github agent-shield/v2-ring0 12b0075a9c48000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"effective-permission diagnostic"* ]]
  [[ "$output" != *"parse error"* ]]
  [[ "$output" == *"total_count=<unreadable>"* ]]
}

# ── orchestrator: sync-issues — auto-triage held promotions into tracked issues ──
# A held (BLOCKED) promotion files/updates ONE idempotent issue per agent with the failing-run
# evidence; a cleared agent's issue auto-closes; the fleet-status table is rendered to the job
# summary. dev-lead-only registry keeps the fleet loop to one agent; the gh stub logs issue ops.
_sync_stub() {
  # $1 = conclusion (failure→BLOCKED | success→cleared | gap→run-list always fails)
  # $2 = blocker-list JSON returned by `gh issue list`
  # $3 = blob_mode: "same" (default, ref=cccc and ref=bbbb return identical blobs)
  #               or "differ" (ref=cccc and ref=bbbb return distinct blobs → reusable differs)
  # dev-lead is cross-repo (host=.github-private, THIS_REPO=.github): channel tags, release
  # date, and reusable blobs resolve via gh api; git is a no-op.
  local concl="$1" blocker_list="${2:-[]}" blob_mode="${3:-same}"
  local cccc_blob="blobAAAA" bbbb_blob="blobAAAA"
  [ "$blob_mode" = "differ" ] && { cccc_blob="reuseCAND"; bbbb_blob="reusePRIOR"; }
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local cut_iso run_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  local run_list_case
  if [ "$concl" = "gap" ]; then
    run_list_case='echo "gh: run history unavailable (HTTP 500)" >&2; exit 1'
  else
    run_list_case="jq -nc --arg d \"$run_iso\" --arg c \"$concl\" '[range(3)|{conclusion:\$c,createdAt:\$d,databaseId:12345,workflowName:\"Dev-Lead Agent\"}]'"
  fi
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "$cccc_blob" ;;
  *"ref=bbbb"*) echo "$bbbb_blob" ;;
  *"run list"*) $run_list_case ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Some step","conclusion":"failure"}]}]}' ;;
  "issue list"*) echo '$blocker_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "issue pin"*)    echo "PIN|\$*"    >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  SYNC_RINGS="$BATS_TEST_TMPDIR/sync-rings.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$SYNC_RINGS"
}

@test "orchestrator: sync-issues --dry-run plans the blocker + renders status, no GitHub writes" {
  _sync_stub failure '[]'   # BLOCKED, nothing filed yet
  # Pin GITHUB_STEP_SUMMARY to a temp file — under CI the runner sets it, so the table lands
  # in the summary, not stdout; asserting the file keeps the test env-independent.
  local summ="$BATS_TEST_TMPDIR/summary.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would OPEN blocker issue for dev-lead"* ]]
  grep -q "Canary Rollout — fleet status" "$summ"   # table still renders under --dry-run
  [ ! -s "$ISSUE_LOG" ]   # dry-run mutates nothing on GitHub
}

@test "orchestrator: sync-issues opens ONE blocker issue (with evidence) + writes the fleet summary — no dashboard issue" {
  _sync_stub failure '[]'
  local summ="$BATS_TEST_TMPDIR/summary.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  [[ "$output" == *"wrote fleet-status table to the job summary"* ]]
  # Exactly ONE issue create (the blocker) — the dashboard is NOT an issue anymore.
  run grep -c '^CREATE|' "$ISSUE_LOG"
  [ "$output" -eq 1 ]
  grep -q -- "--label canary-blocker" "$ISSUE_LOG"
  ! grep -q -- "--label canary-dashboard" "$ISSUE_LOG"
  ! grep -q "^PIN|" "$ISSUE_LOG"
  # Blocker is ROUTED to the dev-lead agent for action (label applied via the App token,
  # so the `issues: labeled` event triggers dev-lead) — not left sitting unowned.
  grep -q -- "--add-label dev-lead" "$ISSUE_LOG"
  # The fleet-status table landed in the job summary file.
  grep -q "Canary Rollout — fleet status" "$summ"
  grep -q "dev-lead" "$summ"
}

@test "orchestrator: sync-issues survives a failing 'gh issue create' — no abort under set -e, still renders the fleet summary (#1081)" {
  # Regression: the blocker-issue create failing (App lacks Issues:write, rate-limit, …)
  # must NOT abort the whole step before the dashboard renders. Make `gh issue create` exit
  # non-zero and assert graceful degradation: warning logged, table still written, status 0.
  _sync_stub failure '[]'
  sed 's#"issue create"\*).*#"issue create"*) echo "gh: HTTP 403 (Issues:write?)" >\&2; exit 1 ;;#' "$STUB_BIN/gh" > "$STUB_BIN/gh.tmp" && mv "$STUB_BIN/gh.tmp" "$STUB_BIN/gh" && chmod +x "$STUB_BIN/gh"
  local summ="$BATS_TEST_TMPDIR/summary_fail.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not open blocker issue for dev-lead (Issues:write on the App?)"* ]]
  [[ "$output" == *"wrote fleet-status table to the job summary"* ]]
  grep -q "Canary Rollout — fleet status" "$summ"
  grep -q "dev-lead" "$summ"
}

@test "orchestrator: sync-issues auto-closes a cleared agent's open blocker issue" {
  # dev-lead now clean (success → not BLOCKED) but an OPEN blocker issue #501 exists → close it.
  _sync_stub success '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed cleared blocker issue #501 for dev-lead"* ]]
  grep -q "CLOSE|.*501" "$ISSUE_LOG"
}

@test "orchestrator: sync-issues prepends a separator newline so the fleet-status header is never concatenated to prior summary content" {
  # If prior summary content lacks a trailing newline, the fleet-status header must still
  # start on its own line — not be appended directly to the prior content.
  _sync_stub success '[]'
  local summ="$BATS_TEST_TMPDIR/summary_sep.md"
  printf 'prior step output (no trailing newline)' > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  # The header must appear at the start of a line — not concatenated onto the prior content.
  grep -q '^# Canary Rollout' "$summ"
  ! grep -q 'prior.*# Canary Rollout' "$summ"
}

# ── orchestrator: sync-promotion-failures — escalate failing tag WRITES (#1023 defect 2) ─
# A failed tag write (recorded in CANARY_PROMOTIONS_FAILED_LOG by promote) becomes a durable
# per-agent tracking issue whose CONSECUTIVE-failure streak escalates to needs-human + dev-lead
# at the threshold, and auto-closes when a write succeeds (agent in CANARY_PROMOTIONS_LOG).
_promo_fail_sync_stub() {
  local issue_list="${1:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  "issue list"*)   echo '$issue_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github/issues/900" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "orchestrator: sync-promotion-failures opens a tracking issue on the FIRST failure — not yet escalated (#1023)" {
  _promo_fail_sync_stub '[]'
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened promotion-failure issue #900 for dev-lead (count=1)"* ]]
  grep -q -- "--label canary-promotion-failure" "$ISSUE_LOG"
  # count=1 < threshold(2): NOT escalated — no needs-human on the first failure.
  ! grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

@test "orchestrator: sync-promotion-failures escalates (needs-human + dev-lead) at the Nth consecutive failure (#1023)" {
  # An existing tracking issue already at count=1; another failure this run → count=2 = threshold.
  local existing='[{"number":901,"state":"OPEN","body":"<!-- canary-promo-fail:dev-lead -->\n<!-- canary-promo-fail-count:1 -->"}]'
  _promo_fail_sync_stub "$existing"
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTION_FAILURE_ESCALATE_AFTER=2 CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated promotion-failure issue #901 for dev-lead (count=2)"* ]]
  grep -q -- "issue edit 901 .*--add-label dev-lead --add-label needs-human" "$ISSUE_LOG"
}

@test "orchestrator: sync-promotion-failures — a successful ring move does not mask a failed write for the same agent (#1023)" {
  local existing='[{"number":903,"state":"OPEN","body":"<!-- canary-promo-fail:dev-lead -->\n<!-- canary-promo-fail-count:1 -->"}]'
  _promo_fail_sync_stub "$existing"
  local flog="$BATS_TEST_TMPDIR/pf.tsv" slog="$BATS_TEST_TMPDIR/ok.tsv"
  printf 'dev-lead\tstable\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\n' > "$slog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTION_FAILURE_ESCALATE_AFTER=2 CANARY_PROMOTIONS_FAILED_LOG="$flog" CANARY_PROMOTIONS_LOG="$slog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated promotion-failure issue #903 for dev-lead (count=2)"* ]]
  ! grep -q "^CLOSE|" "$ISSUE_LOG"
}

@test "orchestrator: sync-promotion-failures auto-closes the tracking issue when the write recovers (#1023)" {
  # dev-lead succeeded this run (in the SUCCESS log) but an OPEN failure issue exists → close it.
  local existing='[{"number":902,"state":"OPEN","body":"<!-- canary-promo-fail:dev-lead -->\n<!-- canary-promo-fail-count:3 -->"}]'
  _promo_fail_sync_stub "$existing"
  local slog="$BATS_TEST_TMPDIR/ok.tsv"; printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\n' > "$slog"
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; : > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTIONS_LOG="$slog" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed recovered promotion-failure issue #902 for dev-lead"* ]]
  grep -q "CLOSE|.*902" "$ISSUE_LOG"
}

@test "orchestrator: sync-promotion-failures gives success precedence when agent is in both logs (#1023)" {
  # dev-lead failed initially (in FAILED log) but succeeded later (in SUCCESS log); success takes precedence.
  local existing='[{"number":903,"state":"OPEN","body":"<!-- canary-promo-fail:dev-lead -->\n<!-- canary-promo-fail-count:1 -->"}]'
  _promo_fail_sync_stub "$existing"
  local slog="$BATS_TEST_TMPDIR/ok.tsv"; printf 'dev-lead\tring0\tdddddddddddddddd\tpetry-projects/.github-private\n' > "$slog"
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTIONS_LOG="$slog" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed recovered promotion-failure issue #903 for dev-lead"* ]]
  grep -q "CLOSE|.*903" "$ISSUE_LOG"
}

@test "orchestrator: sync-promotion-failures — a ring0 success must NOT hide a ring1 failure from the same run (#1118)" {
  # One run can now advance several rings. ring0 moved, ring1's tag write was rejected: the agent is
  # FAILED (its tracking issue stays/gets opened), not "recovered".
  local existing='[{"number":905,"state":"OPEN","body":"<!-- canary-promo-fail:dev-lead -->\n<!-- canary-promo-fail-count:1 -->"}]'
  _promo_fail_sync_stub "$existing"
  local slog="$BATS_TEST_TMPDIR/ok.tsv"; printf 'dev-lead\tring0\tdddddddddddddddd\tpetry-projects/.github-private\n' > "$slog"
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; printf 'dev-lead\tring1\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTIONS_LOG="$slog" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated promotion-failure issue #905 for dev-lead (count=2)"* ]]
  [[ "$output" != *"closed recovered"* ]]
  run grep -q "CLOSE|.*905" "$ISSUE_LOG"
  [ "$status" -eq 1 ]
}

@test "orchestrator: sync-promotion-failures does NOT seed a new streak from a CLOSED issue (#1023)" {
  # A CLOSED tracking issue with a high prior count must not seed the next streak:
  # the first new failure after recovery should start at count=1 (not count=6).
  local existing='[{"number":904,"state":"CLOSED","body":"<!-- canary-promo-fail:dev-lead -->\n<!-- canary-promo-fail-count:5 -->"}]'
  _promo_fail_sync_stub "$existing"
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTION_FAILURE_ESCALATE_AFTER=2 CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"(count=1)"* ]]
  ! grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

@test "orchestrator: sync-promotion-failures --dry-run plans but writes nothing to GitHub (#1023)" {
  _promo_fail_sync_stub '[]'
  local flog="$BATS_TEST_TMPDIR/pf.tsv"; printf 'dev-lead\tring0\tccccccccccccccccc\tpetry-projects/.github-private\ttag write rejected\n' > "$flog"
  run env ISSUE_REPO="petry-projects/.github" CANARY_PROMOTIONS_FAILED_LOG="$flog" bash "$ORCH" sync-promotion-failures --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would OPEN promotion-failure issue for dev-lead"* ]]
  [ ! -s "$ISSUE_LOG" ]
}

@test "orchestrator: sync-promotion-failures is a clean no-op when no promotion was attempted (#1023)" {
  _promo_fail_sync_stub '[]'
  run env ISSUE_REPO="petry-projects/.github" bash "$ORCH" sync-promotion-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"no promotion attempts recorded this run"* ]]
  [ ! -s "$ISSUE_LOG" ]
}

# ── orchestrator: autocut — auto-cut a new candidate when a reusable changes on main (#1069) ─
# The front end of the canary pipeline: at each scheduled tick (gated by CANARY_AUTO_CUT), for
# each registered agent compare the reusable blob at the host's main HEAD against the blob at the
# current `next` candidate; if they differ, cut a new immutable vX.Y.Z (patch bump default) and
# move `next` onto it INLINE via the App-token gh-api path (create annotated tag + move ref) —
# no sibling cut-release.sh (#613). The stub feeds: default_branch, main HEAD, the two blob SHAs,
# the `next` commit (git for a this-repo agent, gh api for a cross-repo one), the existing
# release-tag versions (matching-refs), and LOGS every mutating gh-api call (tag/ref writes) to
# GH_LOG so a test can assert the cut hit the right host without a cut-release.sh stand-in.
_autocut_stub() {
  # args: agent host reusable main_blob next_blob mainsha nextsha versions_ws [bump [existing_tag_sha]]
  # existing_tag_sha: if set, the release-tag existence probe returns this sha (simulates a prior
  # partial cut); if empty (default), the probe returns nothing (fresh cut path).
  local agent="$1" host="$2" reusable="$3" MAIN_BLOB="$4" NEXT_BLOB="$5" MAINSHA="$6" NEXTSHA="$7" versions="$8" bump="${9:-}" existing_tag_sha="${10:-}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$STUB_BIN/gh-writes.log"; : > "$GH_LOG"
  local refs="" v
  for v in $versions; do refs+="refs/tags/$agent/v$v"$'\n'; done
  # Build the probe response: empty → tag not yet cut; "<sha>\tcommit" → existing tag at that sha.
  local tag_probe_resp=""
  [ -n "$existing_tag_sha" ] && tag_probe_resp="${existing_tag_sha}"$'\t'"commit"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *".default_branch"*) echo "main" ;;
  *"contents/"*"ref=$MAINSHA"*) echo "$MAIN_BLOB" ;;
  *"contents/"*"ref=$NEXTSHA"*) echo "$NEXT_BLOB" ;;
  # inline cut (mutating writes) — log to GH_LOG and simulate success:
  *"-X POST"*"git/tags"*) echo "\$*" >> "$GH_LOG"; echo "7a90000000000000000000000000000000000000" ;;  # create annotated tag object
  *"-X PATCH"*"git/refs/tags/$agent/next"*) echo "\$*" >> "$GH_LOG"; exit 0 ;;                          # move next (force PATCH)
  *"-X POST"*"git/refs"*) echo "\$*" >> "$GH_LOG"; echo "{}" ;;                                          # publish a ref
  *"/commits/"*) echo "$MAINSHA" ;;
  *"matching-refs/tags/$agent/v"*) printf '%s' "$refs" ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  # bare-tier fleet: no v-scoped channel tags exist yet (v<M>-next), so a v-channel
  # probe resolves absent — only the vX.Y.Z RELEASE existence probe returns tag_probe_resp.
  *"git/ref/tags/$agent/v"*"-next"*) printf '\n' ;;
  *"git/ref/tags/$agent/v"*) printf '%s\n' "$tag_probe_resp" ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"$agent/next"*) echo "$NEXTSHA" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  AUTOCUT_RINGS="$BATS_TEST_TMPDIR/autocut-rings.json"
  if [ -n "$bump" ]; then
    jq --arg a "$agent" --arg b "$bump" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): (.agents[$a] + {autocut: {bump: $b}})}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  else
    jq --arg a "$agent" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): .agents[$a]}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  fi
}

@test "orchestrator: autocut is a no-op when CANARY_AUTO_CUT is not 'true' (kill-switch off)" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
  [ ! -s "$GH_LOG" ]   # nothing cut when the kill-switch is off
}

@test "orchestrator: autocut cuts a patch-bumped version + moves next when the reusable blob differs on main" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # Highest existing tag is v2.1.0 → patch bump → v2.1.1, annotated tag cut from main HEAD on the
  # HOST repo (.github-private for dev-lead), then `next` force-moved onto the same commit — all gh-api.
  grep -q "repos/petry-projects/.github-private/git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut is idempotent — identical blob on main and next is a clean no-op" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    sameBLOB sameBLOB aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cut"* ]]
  [ ! -s "$GH_LOG" ]   # nothing cut when the blob is unchanged
}

@test "orchestrator: autocut --dry-run prints the intended cut without writing any tag" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"2.1.1"* ]]
  [ ! -s "$GH_LOG" ]   # dry-run never writes a real cut
}

@test "orchestrator: autocut honors the registry autocut.bump override (minor)" {
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" minor
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # minor bump of v2.1.0 → v2.2.0
  grep -q "repos/petry-projects/.github-private/git/tags .*tag=dev-lead/v2.2.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut is cross-repo aware — cuts v2.1.1 for auto-rebase on the host repo (#1069)" {
  # auto-rebase is hosted in petry-projects/.github; its next candidate + release tags live there,
  # so the next commit is resolved via gh api (not local git) and BOTH the tag create and the
  # next move are written to that host — not GITHUB_REPOSITORY.
  _autocut_stub auto-rebase petry-projects/.github .github/workflows/auto-rebase-reusable.yml \
    ece45480ece45480ece45480ece45480ece45480 2763750027637500276375002763750027637500 \
    ece45480ece45480ece45480ece45480ece45480 2763750027637500276375002763750027637500 "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "repos/petry-projects/.github/git/tags .*tag=auto-rebase/v2.1.1 .*object=ece45480ece45480ece45480ece45480ece45480" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github/git/refs/tags/auto-rebase/next .*sha=ece45480ece45480ece45480ece45480ece45480" "$GH_LOG"
}

@test "orchestrator: autocut — existing release tag matching mainsha skips create and still moves next (idempotent retry)" {
  # Simulate a partial retry: the release tag was already created on a prior run (pointing to
  # mainsha), but `next` was not yet moved. The idempotency branch must skip POST git/tags
  # and proceed straight to the PATCH for next without calling _gh_create_annotated_tag.
  local mainsha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT "$mainsha" cccccccccccccccccccccccccccccccccccccccc "2.1.0" "" "$mainsha"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [[ "$output" == *"re-pointing next only"* ]]
  # The annotated tag create (POST git/tags) must NOT be called — tag already exists.
  ! grep -q "POST.*git/tags" "$GH_LOG"
  # The next move (PATCH) must still happen to complete the idempotent operation.
  grep -q "PATCH.*git/refs/tags/dev-lead/next" "$GH_LOG"
}

@test "orchestrator: autocut — existing release tag pointing to a different commit emits warning and skips next move" {
  # If vX.Y.Z already exists but points to a different commit (manual retag, concurrent run,
  # prior bad state), moving next to mainsha would violate the "release tag + next → same commit"
  # invariant. The engine must warn and skip rather than advance next to an untagged commit.
  local mainsha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local stale_sha="dddddddddddddddddddddddddddddddddddddddd"
  _autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT "$mainsha" cccccccccccccccccccccccccccccccccccccccc "2.1.0" "" "$stale_sha"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  # Neither tag create nor next move may be written when the invariant check fails.
  [ ! -s "$GH_LOG" ]
}

# ── set_difference (pure set-diff core for drift detection, #1082) ─────────────
# args: <set_a_newlines> <set_b_newlines> — echo lines in A that are NOT in B.
@test "set_difference: A minus B keeps only A-only elements" {
  run set_difference "$(printf 'a\nb\nc\n')" "$(printf 'b\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\nc')" ]
}
@test "set_difference: no overlap returns all of A" {
  run set_difference "$(printf 'x\ny\n')" "$(printf 'p\nq\n')"
  [ "$output" = "$(printf 'x\ny')" ]
}
@test "set_difference: full overlap returns nothing" {
  run set_difference "$(printf 'a\nb\n')" "$(printf 'a\nb\n')"
  [ -z "$output" ]
}
@test "set_difference: empty A returns nothing" {
  run set_difference "" "$(printf 'a\n')"
  [ -z "$output" ]
}
@test "set_difference: empty B returns all of A (nothing removed)" {
  run set_difference "$(printf 'a\nb\n')" ""
  [ "$output" = "$(printf 'a\nb')" ]
}
@test "set_difference: matches whole lines only (a path is not a prefix match)" {
  # '.github/workflows/foo-reusable.yml' must not be swallowed by a partial 'foo'.
  run set_difference "$(printf '.github/workflows/foo-reusable.yml\n')" "$(printf 'foo\n')"
  [ "$output" = ".github/workflows/foo-reusable.yml" ]
}

# ── orchestrator: drift — registry vs host reusables (read-only audit, #1082) ──
# The registry (.agents{}) is the MANUAL source of truth for what the canary pipeline
# manages. `drift` scans each registered host repo's .github/workflows/*-reusable.yml
# and diffs it against the registry so an unregistered reusable (zero staged rollout) OR
# a registry entry pointing at a deleted reusable surfaces within one scheduled cycle.
#
# The stub answers `gh api repos/<host>/contents/.github/workflows` with a per-host JSON
# array (env HOSTPRIV_JSON / HOSTPUB_JSON); the orchestrator filters *-reusable.yml itself.
_drift_stub() {
  # $1 = JSON array for petry-projects/.github-private ; $2 = JSON array for petry-projects/.github
  local priv_json="$1" pub_json="${2:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  # '.github' is a substring of '.github-private', so match the more specific repo FIRST.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"repos/petry-projects/.github-private/contents/.github/workflows"*) cat <<'JSON'
$priv_json
JSON
    ;;
  *"repos/petry-projects/.github/contents/.github/workflows"*) cat <<'JSON'
$pub_json
JSON
    ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # drift never touches git
GITEOF
  chmod +x "$STUB_BIN/git"
}

# A registry with a single this-repo agent (dev-lead) so the present/registered sets are
# fully controlled: registered on .github-private = {dev-lead-reusable.yml}, none on .github.
_drift_rings_one_agent() {
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-rings.json"
  jq '{version, description, org_infra_repos, member_tokens, agents: {"dev-lead": .agents["dev-lead"]}}' \
    "$RINGS" > "$DRIFT_RINGS"
}

@test "orchestrator: drift flags a reusable present on a host but absent from the registry (unregistered)" {
  _drift_rings_one_agent
  # .github-private hosts an EXTRA foo-reusable.yml that no .agents{} block registers.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"},
    {"type":"file","name":"ci.yml","path":".github/workflows/ci.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[unregistered]"* ]]
  [[ "$output" == *".github/workflows/foo-reusable.yml"* ]]
  # the registered reusable and the non-reusable ci.yml are NOT flagged
  [[ "$output" != *"DRIFT[unregistered] petry-projects/.github-private: .github/workflows/dev-lead-reusable.yml"* ]]
  [[ "$output" != *"ci.yml present on host"* ]]
}

@test "orchestrator: drift excludes an intentionally-unmanaged reusable (#651)" {
  # Registry: dev-lead agent + an `unmanaged` entry for foo-reusable.yml on .github-private.
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-rings-um.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"dev-lead": .agents["dev-lead"]},
       unmanaged: {"foo": {"host":"petry-projects/.github-private","reusable":".github/workflows/foo-reusable.yml","reason":"single-hop infra (#651)"}}}' \
    "$RINGS" > "$DRIFT_RINGS"
  # host has dev-lead (registered) + foo (unmanaged) + bar (genuinely unregistered)
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"},
    {"type":"file","name":"bar-reusable.yml","path":".github/workflows/bar-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  # foo is reported as unmanaged, NOT flagged as unregistered drift
  [[ "$output" == *"unmanaged (intentional"* ]]
  [[ "$output" != *"DRIFT[unregistered] petry-projects/.github-private: .github/workflows/foo-reusable.yml"* ]]
  # bar (neither registered nor unmanaged) IS still flagged, and it's the ONLY one
  [[ "$output" == *"DRIFT[unregistered] petry-projects/.github-private: .github/workflows/bar-reusable.yml"* ]]
  [[ "$output" == *"1 unregistered"* ]]
}

@test "orchestrator: drift flags a registry entry whose reusable file no longer exists on the host (missing-file)" {
  # Registry has 'ghost' pointing at a reusable that is NOT present on the host.
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-ghost.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"ghost": (.agents["dev-lead"] + {reusable: ".github/workflows/ghost-reusable.yml"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  # Host lists only an unrelated (registered-elsewhere-none) file — ghost-reusable.yml is gone.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[missing-file]"* ]]
  [[ "$output" == *"ghost"* ]]
  [[ "$output" == *".github/workflows/ghost-reusable.yml"* ]]
}

# #1166: a registered reusable kept on a grandfathered name (no `-reusable.yml` suffix, e.g.
# the pr-review engine `pr-review.yml`, #1127) that IS present on the host must NOT be
# false-flagged missing-file. Before the fix, drift's present-set was suffix-only, so
# registering pr-review.yml raised a spurious "stale registry entry" warning every cycle.
@test "orchestrator: drift does NOT false-flag a present grandfathered-named reusable (pr-review.yml, #1166)" {
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-grandfathered.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"pr-review": (.agents["dev-lead"] + {host: "petry-projects/.github-private",
                                                     reusable: ".github/workflows/pr-review.yml"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  # The host listing includes pr-review.yml (present, but not `-reusable.yml`).
  _drift_stub '[
    {"type":"file","name":"pr-review.yml","path":".github/workflows/pr-review.yml"},
    {"type":"file","name":"pr-review-trigger.yml","path":".github/workflows/pr-review-trigger.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  # pr-review.yml is registered AND present → neither missing-file nor unregistered.
  [[ "$output" != *"DRIFT[missing-file]"* ]]
  [[ "$output" != *"DRIFT[unregistered] petry-projects/.github-private: .github/workflows/pr-review.yml"* ]]
  [[ "$output" == *"0 unregistered, 0 missing-file"* ]]
}

# A grandfathered-named reusable that is registered but GENUINELY absent from the host
# listing must still be reported missing — the fix admits present registered files, it does
# not blanket-suppress the check (#1166).
@test "orchestrator: drift still reports a registered grandfathered reusable that is truly gone (#1166)" {
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-grandfathered-gone.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"pr-review": (.agents["dev-lead"] + {host: "petry-projects/.github-private",
                                                     reusable: ".github/workflows/pr-review.yml"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  # Host listing does NOT contain pr-review.yml — the file is genuinely gone.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[missing-file]"* ]]
  [[ "$output" == *".github/workflows/pr-review.yml"* ]]
}

# A registered path to a present NON-YAML file is not a reusable workflow: the registered-path
# exception is restricted to .yml/.yaml, so the audit still flags it missing-file (cubic review on #1124).
@test "orchestrator: drift still flags a registered non-YAML path even when present on the host" {
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-nonyaml.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"pr-review": (.agents["dev-lead"] + {host: "petry-projects/.github-private",
                                                     reusable: ".github/workflows/README.md"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  _drift_stub '[
    {"type":"file","name":"README.md","path":".github/workflows/README.md"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[missing-file]"* ]]
}

@test "orchestrator: drift reports NO drift when the registry and host reusables are in sync" {
  _drift_rings_one_agent
  # Host lists exactly the one registered reusable — nothing extra, nothing missing.
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT["* ]]
  [[ "$output" == *"no reusable drift"* ]]
  [[ "$output" == *"0 unregistered, 0 missing-file"* ]]
}

@test "orchestrator: drift --emit-stub prints a scaffold .agents[<name>] block for an unregistered reusable" {
  _drift_rings_one_agent
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"}
  ]' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift --emit-stub
  [ "$status" -eq 0 ]
  # A scaffold JSON object keyed by the derived agent name 'foo' the maintainer can fill in.
  [[ "$output" == *"\"foo\""* ]]
  [[ "$output" == *"\"reusable\": \".github/workflows/foo-reusable.yml\""* ]]
  [[ "$output" == *"petry-projects/.github-private"* ]]
}

@test "orchestrator: drift skips a host it cannot enumerate — no false missing-file avalanche" {
  # Registry has 'ghost' on .github-private, but the contents API returns a non-array error
  # body (no access / API error). The host must be SKIPPED, NOT reported as every registered
  # reusable having been deleted.
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-noaccess.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"ghost": (.agents["dev-lead"] + {reusable: ".github/workflows/ghost-reusable.yml"})}}' \
    "$RINGS" > "$DRIFT_RINGS"
  _drift_stub '{"message":"Not Found"}' '[]'
  run env CANARY_RINGS="$DRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not enumerate"* ]]
  [[ "$output" != *"DRIFT[missing-file]"* ]]
  [[ "$output" == *"0 unregistered, 0 missing-file"* ]]
}

@test "orchestrator: drift renders a fleet-drift table into the job summary when GITHUB_STEP_SUMMARY is set" {
  _drift_rings_one_agent
  _drift_stub '[
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"},
    {"type":"file","name":"foo-reusable.yml","path":".github/workflows/foo-reusable.yml"}
  ]' '[]'
  local summ="$BATS_TEST_TMPDIR/drift-summary.md"; : > "$summ"
  run env CANARY_RINGS="$DRIFT_RINGS" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  grep -q "Canary Rollout — reusable drift" "$summ"
  grep -q "foo-reusable.yml" "$summ"
}

# ── registry COMPLETENESS: a channel-tagged agent absent from the registry (#1106) ────────────
# Registry SELF-CONSISTENCY (RING_REUSABLES == .agents == the dispatch enum) is asserted by unit
# tests, but it says nothing about COMPLETENESS: an agent can be fully deployed — carrying
# <agent>/v<M>-<tier> channel tags on its host — yet be MISSING from .agents{}, so nothing cuts,
# soaks, gates, or ships it. That is exactly how pr-review ran an 82-day-old build unnoticed. This
# sweep inventories both infra repos' channel tags and flags any agent that has a v-scoped channel
# tag but no registry entry (excluding reserved non-agent namespaces like `standards`).

# _completeness_stub <priv_tags_json> [priv_contents_json] — stub gh so .github-private's
# matching-refs/tags returns <priv_tags_json> (a JSON array of {"ref":...}) and its workflows dir
# returns <priv_contents_json> (default []); .github returns empty tags + empty workflows so only
# the injected private-host tags drive the completeness verdict. git is a no-op.
_completeness_stub() {
  local priv_tags="$1" priv_contents="${2:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *".github-private/git/matching-refs/tags"*) cat <<'JSON'
$priv_tags
JSON
    ;;
  *"git/matching-refs/tags"*) echo '[]' ;;
  *".github-private/contents/.github/workflows"*) cat <<'JSON'
$priv_contents
JSON
    ;;
  *"contents/.github/workflows"*) echo '[]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # completeness never touches git
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: drift completeness flags a channel-tagged agent absent from the registry (#1106)" {
  # Registry knows only dev-lead; standards is a reserved (non-agent) tag namespace.
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-rings.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"],
       agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$COMP_RINGS"
  _completeness_stub '[
    {"ref":"refs/tags/pr-review/v1-next"},
    {"ref":"refs/tags/pr-review/v1-stable"},
    {"ref":"refs/tags/pr-review/v1.8.0"},
    {"ref":"refs/tags/dev-lead/v1-next"},
    {"ref":"refs/tags/standards/v1-stable"}
  ]'
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  # pr-review has channel tags on the host but no registry entry → flagged.
  [[ "$output" == *"DRIFT[registry-incomplete]"* ]]
  [[ "$output" == *"pr-review"* ]]
  # a registered agent (dev-lead) and the reserved `standards` namespace are NOT flagged;
  # a release tag (pr-review/v1.8.0) is not a channel tag and never drives this verdict.
  [[ "$output" != *"registry-incomplete] petry-projects/.github-private: 'dev-lead'"* ]]
  [[ "$output" != *"registry-incomplete] petry-projects/.github-private: 'standards'"* ]]
  # exactly one completeness finding (pr-review), counted once across both repos.
  [[ "$output" == *"registry-completeness summary: 1"* ]]
}

@test "orchestrator: drift completeness flags an unregistered agent with tags on .github (both repos checked, #1106)" {
  # Registry knows only dev-lead; an unregistered agent has tags on .github (not .github-private).
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-github-tags.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"],
       agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$COMP_RINGS"
  # Override the stub to return tags for .github (the public infra repo) as well.
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *".github-private/git/matching-refs/tags"*) echo '[]' ;;
  *"petry-projects/.github/git/matching-refs/tags"*)
    # Unregistered-agent tags ONLY on the public .github repo: a sweep that skips it would pass vacuously
    cat <<'JSON'
[{"ref":"refs/tags/unregistered-agent/v1-next"},{"ref":"refs/tags/unregistered-agent/v1-stable"},{"ref":"refs/tags/dev-lead/v1-next"}]
JSON
    ;;
  *"contents/.github/workflows"*) echo '[]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # completeness never touches git
GITEOF
  chmod +x "$STUB_BIN/git"
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  # unregistered-agent has channel tags but is not in the registry → flagged
  [[ "$output" == *"DRIFT[registry-incomplete]"* ]]
  [[ "$output" == *"unregistered-agent"* ]]
  [[ "$output" == *"registry-completeness summary: 1"* ]]
}

@test "orchestrator: drift completeness is clean once every channel-tagged agent is registered (#1106)" {
  # Both dev-lead and pr-review are registered; standards is reserved → no completeness gap.
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-clean-rings.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"],
       agents: {"dev-lead": .agents["dev-lead"], "pr-review": .agents["pr-review"]}}' "$RINGS" > "$COMP_RINGS"
  # workflows dir lists the registered reusables so the reusable-drift pass stays clean too.
  _completeness_stub '[
    {"ref":"refs/tags/pr-review/v1-next"},
    {"ref":"refs/tags/pr-review/v1-stable"},
    {"ref":"refs/tags/dev-lead/v1-next"},
    {"ref":"refs/tags/standards/v1-stable"}
  ]' '[
    {"type":"file","name":"pr-review.yml","path":".github/workflows/pr-review.yml"},
    {"type":"file","name":"dev-lead-reusable.yml","path":".github/workflows/dev-lead-reusable.yml"}
  ]'
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"registry-completeness summary: 0"* ]]
  [[ "$output" != *"DRIFT[registry-incomplete]"* ]]
}

@test "orchestrator: drift completeness skips the sweep when the registry has no agents (no false positives)" {
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-empty-rings.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"], agents: {}}' "$RINGS" > "$COMP_RINGS"
  _completeness_stub '[
    {"ref":"refs/tags/pr-review/v1-next"}
  ]'
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [[ "$output" == *"registry completeness: .agents{} is empty or unreadable"* ]]
  [[ "$output" == *"completeness check was INCOMPLETE"* ]]
  [[ "$output" != *"DRIFT[registry-incomplete]"* ]]
}

@test "orchestrator: drift with an empty registry and GITHUB_STEP_SUMMARY set exits 0 and names the skipped sweep" {
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-empty-summary.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"], agents: {}}' "$RINGS" > "$COMP_RINGS"
  _completeness_stub '[]'
  SUMMARY="$BATS_TEST_TMPDIR/step-summary.md"; : > "$SUMMARY"
  run env CANARY_RINGS="$COMP_RINGS" GITHUB_STEP_SUMMARY="$SUMMARY" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  grep -q "Completeness sweep was skipped" "$SUMMARY"
  ! grep -q "attempts (API errors" "$SUMMARY"
}

@test "orchestrator: drift completeness flags an unregistered agent that has only bare channel tags (#1106)" {
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-bare.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"],
       agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$COMP_RINGS"
  _completeness_stub '[
    {"ref":"refs/tags/bare-agent/stable"},
    {"ref":"refs/tags/bare-agent/next"},
    {"ref":"refs/tags/dev-lead/stable"},
    {"ref":"refs/tags/standards/stable"},
    {"ref":"refs/tags/release-only/v1.2.3"}
  ]'
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[registry-incomplete]"*"'bare-agent'"* ]]
  # registered (dev-lead), reserved (standards) and release-only tags are not flagged
  [[ "$output" != *"registry-incomplete] petry-projects/.github-private: 'dev-lead'"* ]]
  [[ "$output" != *"registry-incomplete] petry-projects/.github-private: 'standards'"* ]]
  [[ "$output" != *"release-only"* ]]
  [[ "$output" == *"registry-completeness summary: 1"* ]]
}

@test "orchestrator: drift completeness ignores release tags that lack a channel tier (#1106)" {
  # Registry knows only dev-lead; release-only-agent has only release tags (no v<M>-<tier> tags).
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-release-only.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"],
       agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$COMP_RINGS"
  _completeness_stub '[
    {"ref":"refs/tags/release-only-agent/v1.0.0"},
    {"ref":"refs/tags/release-only-agent/v1.1.0"},
    {"ref":"refs/tags/dev-lead/v1-next"}
  ]'
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  # release-only-agent is NOT a channel-tag agent (has only vX.Y.Z, no v<M>-<tier>) → not flagged
  [[ "$output" != *"release-only-agent"* ]]
  [[ "$output" == *"registry-completeness summary: 0"* ]]
}

@test "orchestrator: drift completeness skips an infra repo it cannot enumerate (no false gap) (#1106)" {
  COMP_RINGS="$BATS_TEST_TMPDIR/comp-noaccess.json"
  jq '{version, description, org_infra_repos, member_tokens, reserved_tag_namespaces: ["standards"],
       agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$COMP_RINGS"
  # matching-refs returns a non-array error body for .github-private → the repo is skipped,
  # NOT read as "no channel tags" (which would silently miss a real completeness gap).
  _completeness_stub '{"message":"Not Found"}'
  run env CANARY_RINGS="$COMP_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not enumerate channel tags"* ]]
  [[ "$output" != *"DRIFT[registry-incomplete]"* ]]
}

@test "orchestrator: drift does not false-flag a registered non-reusable-suffixed reusable as missing-file (#1106)" {
  # pr-review's reusable is the grandfathered pr-review.yml (no -reusable.yml suffix). It is
  # PRESENT on the host, so the missing-file check must recognise it — not report it as deleted.
  MF_RINGS="$BATS_TEST_TMPDIR/mf-rings.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"pr-review": (.agents["dev-lead"] + {reusable: ".github/workflows/pr-review.yml"})}}' \
    "$RINGS" > "$MF_RINGS"
  _drift_stub '[
    {"type":"file","name":"pr-review.yml","path":".github/workflows/pr-review.yml"},
    {"type":"file","name":"pr-review-trigger.yml","path":".github/workflows/pr-review-trigger.yml"}
  ]' '[]'
  run env CANARY_RINGS="$MF_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIFT[missing-file]"* ]]
  [[ "$output" == *"0 missing-file"* ]]
}

# ── differs-aware benign classes: version_independent (#668) ────────────────────
# At differs=1 (candidate changed the reusable) the benign allowlist normally disables
# entirely — which chronically false-blocked actively-developed agents on inherently
# environmental failures (#864 Dependabot-context startup failures, #664 workload
# timeouts). A class marked `version_independent: true` fails before/independent of the
# candidate's own code, so it stays excluded from cum_fail even at differs=1; every
# unmarked class still disables, preserving the can't-mask-a-regression invariant.

@test "_benign_patterns: differs=0 emits every benign class (unchanged behaviour)" {
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _benign_patterns dev-lead 0"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 2 ]
  [[ "$output" == *"[Dd]ependabot"* ]]
  [[ "$output" == *"[Pp]ush"* ]]
}

@test "_benign_patterns: differs=1 emits ONLY version_independent classes" {
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _benign_patterns dev-lead 1"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 1 ]
  [[ "$output" == *"[Dd]ependabot"* ]]
  [[ "$output" != *"[Pp]ush"* ]]
}

@test "_benign_patterns: differs defaults to 0 (all classes) when omitted" {
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _benign_patterns dev-lead"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 2 ]
}

@test "_benign_patterns: unknown agent key → empty output, no crash (null-safety)" {
  # .agents[$a]? evaluates to null for an absent key; the ?-chain prevents
  # a fatal 'Cannot index null' jq error and returns [] via the // [] fallback.
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _benign_patterns __nonexistent_agent__ 0"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_benign_patterns: agent with no gate field → empty output, no crash (null-safety)" {
  # Construct a minimal rings file where the agent key exists but has no .gate.
  local tmp_rings
  tmp_rings="$(mktemp "$BATS_TEST_TMPDIR/rings-nogate.XXXXXX.json")"
  jq '.agents["no-gate-agent"] = {}' "$RINGS" > "$tmp_rings"
  run env CANARY_RINGS="$tmp_rings" bash -c "source '$ORCH' && _benign_patterns no-gate-agent 0"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# _vi_benign_stub <failed_step_name> — dev-lead is a cross-repo agent (host=.github-private),
# so channel and release tags resolve via gh api (not local git). Layout: next=cccc candidate,
# ring0..stable=bbbb prior; reusable DIFFERS (reuseAAAA vs reuseBBBB → _reusable_differs=1).
# Every tier repo returns failure runs whose failed step is <failed_step_name>, exercising
# _benign_patterns at differs=1 (only version_independent classes active).
_vi_benign_stub() {
  local failed_step="$1"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-3 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-2 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  # gh: channel tags + annotated release tag resolved via api on host (.github-private);
  # blob SHAs differ (reuseAAAA vs reuseBBBB) so _reusable_differs returns 1; run-list
  # feeds 20 failures per repo; run-view returns the injected failed step name.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run list"*) jq -nc --arg d "$run_iso" '[range(20)|{conclusion:"failure",createdAt:\$d,databaseId:99001,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) jq -nc --arg s "$failed_step" '{jobs:[{steps:[{name:\$s,conclusion:"failure"}]}]}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # Cross-repo agent: no local refs; all resolution goes via gh api above.
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # no local refs for a cross-repo agent
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: differs=1 failure matching a version_independent class → excluded → PROMOTE (#668)" {
  # Every in-window failure is the #864 Dependabot-context class (version_independent) —
  # even though the candidate changed the reusable, cum_fail stays 0 and the gate promotes.
  _vi_benign_stub "Dependabot context guard"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"PROMOTE"* ]]
  [[ "$output" == *"benign=80"* ]]   # 20 failures on each of the 4 concrete tier repos, all excluded
  [[ "$output" != *"BLOCKED"* ]]
}

@test "orchestrator: differs=1 failure matching a NON-version_independent class → still BLOCKED+REGRESSION" {
  # The fix-review push class is NOT version_independent (a candidate COULD change push
  # behaviour), so at differs=1 it stays disabled and the failure blocks as a regression.
  _vi_benign_stub "Push fix-review branch"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"REGRESSION"* ]]
}

@test "canary-rings.json: dev-lead dependabot class is version_independent; push class is not (#668)" {
  run jq -e '.agents["dev-lead"].gate.benign_failure_classes[]
             | select(.id=="dependabot-context-dispatch") | .version_independent == true' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '[.agents["dev-lead"].gate.benign_failure_classes[]
              | select(.id=="fix-review-git-push-permission")] | all(has("version_independent") | not)' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: ci-failure-analyst no longer carries dev-lead's cloned (inert) benign classes" {
  # The onboarding clone copied dev-lead's classes verbatim — their workflow regex
  # 'Dev-Lead Agent' could never match a ci-failure-analyst run, so they were dead config.
  run jq -e '.agents["ci-failure-analyst"].gate.benign_failure_classes == []' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: add-to-project gate carries a 'Set up job' startup benign class (#701)" {
  # #701 fix-forward: a pre-existing/environmental 'Set up job' startup failure of the
  # add-to-project reusable was counted in cum_fail and blocked the next->ring0 gate.
  run jq -e '.agents["add-to-project"].gate.benign_failure_classes
             | type == "array" and length >= 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["add-to-project"].gate.benign_failure_classes[]
             | select(.id=="reusable-setup-restricted-secrets")
             | has("id") and has("reason") and has("step") and has("workflow")' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: add-to-project benign class matches a 'Set up job' failure of its caller workflow (#701)" {
  # Functional: drive benign_match with the class's own workflow+step regex.
  wf_re="$(jq -r '.agents["add-to-project"].gate.benign_failure_classes[]
                  | select(.id=="reusable-setup-restricted-secrets") | .workflow' "$RINGS")"
  step_re="$(jq -r '.agents["add-to-project"].gate.benign_failure_classes[]
                    | select(.id=="reusable-setup-restricted-secrets") | .step' "$RINGS")"
  [ "$(benign_match 'Auto-add to Initiatives project' 'Set up job' "$wf_re" "$step_re")" = "yes" ]
  # a normal in-reusable step failure of the same workflow is NOT swept up by this class
  [ "$(benign_match 'Auto-add to Initiatives project' 'Add issue to project' "$wf_re" "$step_re")" = "no" ]
  # and it does not leak onto an unrelated workflow
  [ "$(benign_match 'Dev-Lead Agent' 'Set up job' "$wf_re" "$step_re")" = "no" ]
}

@test "canary-rings.json: add-to-project 'Set up job' class is NOT version_independent (can't mask a differs=1 regression) (#701)" {
  # A 'Set up job' signature could also arise from a candidate breaking the reusable's own
  # YAML, so the class must stay inert at differs=1 (excludes only when byte-identical).
  run jq -e '.agents["add-to-project"].gate.benign_failure_classes[]
             | select(.id=="reusable-setup-restricted-secrets")
             | .version_independent != true' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── canary-rings.json: auto-rebase infra-outage benign class (#943) ──────────────

@test "canary-rings.json: auto-rebase gate carries a 'Set up job' infra-outage benign class (#943)" {
  run jq -e '.agents["auto-rebase"].gate.benign_failure_classes | type == "array" and length >= 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["auto-rebase"].gate.benign_failure_classes[]
             | select(.id=="runner-action-resolution-outage")
             | has("id") and has("reason") and has("step") and has("workflow")' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: auto-rebase runner-action-resolution-outage class matches a 'Set up job' failure of its caller workflow (#943)" {
  wf_re="$(jq -r '.agents["auto-rebase"].gate.benign_failure_classes[]
                  | select(.id=="runner-action-resolution-outage") | .workflow' "$RINGS")"
  step_re="$(jq -r '.agents["auto-rebase"].gate.benign_failure_classes[]
                    | select(.id=="runner-action-resolution-outage") | .step' "$RINGS")"
  [ "$(benign_match 'Auto-rebase non-Dependabot PRs' 'Set up job' "$wf_re" "$step_re")" = "yes" ]
  # a normal step failure inside the reusable is NOT swept up by this class
  [ "$(benign_match 'Auto-rebase non-Dependabot PRs' 'Rebase PR' "$wf_re" "$step_re")" = "no" ]
  # and it does not leak onto an unrelated workflow
  [ "$(benign_match 'Dev-Lead Agent' 'Set up job' "$wf_re" "$step_re")" = "no" ]
}

@test "canary-rings.json: auto-rebase runner-action-resolution-outage 'Set up job' class is NOT version_independent (can't mask a differs=1 regression) (#943)" {
  # The matcher (_run_signature) only sees failed step NAMES, never log content, so a bare
  # 'Set up job' signature could equally arise from a candidate breaking the reusable's own
  # YAML — same reasoning as add-to-project's reusable-setup-restricted-secrets class. The
  # class must stay inert at differs=1 (excludes only when byte-identical).
  run jq -e '.agents["auto-rebase"].gate.benign_failure_classes[]
             | select(.id=="runner-action-resolution-outage")
             | .version_independent != true' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── SUSPECT triage: suspect_failure_classes (#668 increment 2, #675) ─────────────
# A *possibly-candidate-caused* failure class (dev-lead exit-124 workload timeouts) gets
# the full REGRESSION verdict at differs=1 today, forcing ad-hoc human diagnosis each time.
# A `suspect_failure_classes` entry (matched even at differs=1, unlike benign) instead
# yields SUSPECT: still BLOCKS + needs a human, but carries a discriminating question so the
# confirm is a 30-second check. Default-absent = today's behaviour for agents without it.

@test "_suspect_patterns: emits the dev-lead workload-timeout class (wf/step TSV)" {
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _suspect_patterns dev-lead"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 1 ]
  [[ "$output" == *"Dev-Lead Agent"* ]]
  [[ "$output" == *"Stage timeout"* ]]
}

@test "_suspect_patterns: unknown agent key → empty output, no crash (null-safety)" {
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _suspect_patterns __nonexistent_agent__"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_suspect_patterns: agent with no gate field → empty output, no crash (null-safety)" {
  local tmp_rings
  tmp_rings="$(mktemp "$BATS_TEST_TMPDIR/rings-nogate.XXXXXX.json")"
  jq '.agents["no-gate-agent"] = {}' "$RINGS" > "$tmp_rings"
  run env CANARY_RINGS="$tmp_rings" bash -c "source '$ORCH' && _suspect_patterns no-gate-agent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_suspect_patterns: agent without suspect_failure_classes → empty (default-off, byte-identical)" {
  # agent-shield opts out entirely (no suspect_failure_classes key) → today's behaviour.
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH' && _suspect_patterns agent-shield"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# _suspect_stub <failed_step_name> — like _vi_benign_stub: dev-lead is cross-repo
# (host=.github-private), reusable DIFFERS (reuseAAAA vs reuseBBBB → _reusable_differs=1),
# every tier repo returns failure runs whose failed step is <failed_step_name>. Feeds the
# suspect-class check at differs=1 (where the benign allowlist would otherwise disable).
_suspect_stub() {
  local failed_step="$1"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-3 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-2 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run list"*) jq -nc --arg d "$run_iso" '[range(20)|{conclusion:"failure",createdAt:\$d,databaseId:88002,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) jq -nc --arg s "$failed_step" '{jobs:[{steps:[{name:\$s,conclusion:"failure"}]}]}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # no local refs for a cross-repo agent
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: differs=1 failure matching the suspect class → BLOCKED + SUSPECT (not REGRESSION)" {
  # The exit-124 workload-timeout signature is a suspect class → even though the candidate
  # changed the reusable, it triages SUSPECT (still blocks + needs a human), not REGRESSION.
  _suspect_stub "Stage timeout (exit code 124)"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"REGRESSION"* ]]
}

@test "orchestrator: differs=1 non-suspect failure → still BLOCKED + REGRESSION" {
  # A failure that matches no suspect class stays a full REGRESSION at differs=1.
  _suspect_stub "Compile TypeScript"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"REGRESSION"* ]]
  [[ "$output" != *"SUSPECT"* ]]
}

@test "orchestrator: SUSPECT still BLOCKS — promote refuses without --override" {
  _suspect_stub "Stage timeout (exit code 124)"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"DRY-RUN"* ]]   # no move planned — the gate held
}

@test "orchestrator: SUSPECT is NOT advanced by --allow-pre-existing (only --override)" {
  _suspect_stub "Stage timeout (exit code 124)"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --allow-pre-existing --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"DRY-RUN"* ]]
}

@test "canary-rings.json: dev-lead gate carries a suspect_failure_classes allowlist with guidance" {
  run jq -e '.agents["dev-lead"].gate.suspect_failure_classes | type == "array" and length >= 1' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.suspect_failure_classes
             | all(has("id") and has("workflow") and has("step") and has("reason") and has("guidance"))' "$RINGS"
  [ "$status" -eq 0 ]
  run jq -e '.agents["dev-lead"].gate.suspect_failure_classes[]
             | select(.id=="workload-timeout") | .step | test("124")' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: suspect_failure_classes is default-absent for opted-out agents (byte-identical)" {
  run jq -e '.agents["agent-shield"].gate | has("suspect_failure_classes") | not' "$RINGS"
  [ "$status" -eq 0 ]
}

# ── SUSPECT→PRE_EXISTING auto-downgrade (#668 increment 6) ────────────────────────
# dev-lead's workload-timeout suspect class opts into auto_downgrade: a SUSPECT whose
# candidate suspect-class failure RATE is statistically no-worse than the prior version's
# on the baseline window is auto-cleared to PRE_EXISTING (report-only, no needs-human). The
# genuinely worse case and the tiny-n baseline stay SUSPECT (increment 2). Classes without
# auto_downgrade never downgrade (increment 2 byte-identical).

@test "canary-rings.json: dev-lead workload-timeout opts into auto_downgrade (#668 increment 6)" {
  run jq -e '.agents["dev-lead"].gate.suspect_failure_classes[]
             | select(.id=="workload-timeout") | .auto_downgrade
             | .min_baseline_sample==10 and .margin_permille==100' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: auto_downgrade is dev-lead workload-timeout ONLY (scope guard, #668 increment 6)" {
  # No other agent/class opts in — the increment starts with dev-lead workload-timeout only.
  run jq -e '[.agents[].gate.suspect_failure_classes? // [] | .[] | select(.auto_downgrade != null)] | length == 1' "$RINGS"
  [ "$status" -eq 0 ]
}

# _downgrade_stub <cand_fail> <cand_total> <base_fail> <base_total> — dev-lead cross-repo,
# reusable DIFFERS (reuseAAAA vs reuseBBBB → differs=1). Source-tier CANDIDATE runs (createdAt
# 1d ago, ids ≥2001) and prior-version BASELINE runs (createdAt 7d ago, ids 1001+); in each
# window the first <fail> runs are workload-timeout failures (run view → exit-124 signature)
# and the rest are successes → controls the suspect-class failure RATE + sample per window.
# The `run list` case honours `--created >=<since>` like the real gh, so the candidate window
# (since cut) sees only candidate runs and the baseline window (createdAt < cut) only baseline.
_downgrade_stub() {
  local cand_fail="$1" cand_total="$2" base_fail="$3" base_total="$4"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso cand_iso base_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Stage timeout (exit code 124)","conclusion":"failure"}]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" \
      --argjson cf "$cand_fail" --argjson ct "$cand_total" --argjson bf "$base_fail" --argjson bt "$base_total" '
      ( [range(0;\$ct)|{databaseId:(2001+.),conclusion:(if . < \$cf then "failure" else "success" end),createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(0;\$bt)|{databaseId:(1001+.),conclusion:(if . < \$bf then "failure" else "success" end),createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "orchestrator: SUSPECT + auto_downgrade + cand rate no worse than baseline → PRE_EXISTING (report-only) (#668 inc6)" {
  # cand 1/10 = 100‰, baseline 1/10 = 100‰ (sample 10 ≥ min 10); 100 ≤ 100+100 → DOWNGRADE.
  _downgrade_stub 1 10 1 10
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"PRE_EXISTING"* ]]
  [[ "$output" == *"auto-downgraded"* ]]
}

@test "orchestrator: SUSPECT + auto_downgrade + cand rate materially worse → stays SUSPECT (#668 inc6)" {
  # cand 5/10 = 500‰, baseline 1/10 = 100‰; 500 > 100+100 → HOLD → still SUSPECT + needs a human.
  _downgrade_stub 5 10 1 10
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"auto-downgraded"* ]]
  [[ "$output" != *"PRE_EXISTING"* ]]
}

@test "orchestrator: SUSPECT + auto_downgrade + thin baseline → stays SUSPECT (tiny-n guard) (#668 inc6)" {
  # baseline sample 5 < min 10 → never downgrade on thin data, even though cand==baseline rate.
  _downgrade_stub 1 10 1 5
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"auto-downgraded"* ]]
}

@test "orchestrator: suspect class WITHOUT auto_downgrade → SUSPECT unchanged (increment 2 regression guard, #668 inc6)" {
  # A no-worse baseline that WOULD downgrade if opted in; with auto_downgrade stripped it must
  # stay SUSPECT — proving un-flagged classes are byte-identical to increment 2.
  _downgrade_stub 1 10 1 10
  local no_dg="$BATS_TEST_TMPDIR/no-downgrade-rings.json"
  jq 'del(.agents["dev-lead"].gate.suspect_failure_classes[].auto_downgrade)' "$RINGS" > "$no_dg"
  run env CANARY_RINGS="$no_dg" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"auto-downgraded"* ]]
  [[ "$output" != *"PRE_EXISTING"* ]]
}

@test "orchestrator: an auto-downgraded PRE_EXISTING advances with --allow-pre-existing (#668 inc6)" {
  # Report-only, so --allow-pre-existing (not --override) advances it, exactly like any PRE_EXISTING.
  _downgrade_stub 1 10 1 10
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --allow-pre-existing --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}

# _downgrade_sync_stub <cand_fail> <cand_total> <base_fail> <base_total> — _downgrade_stub plus
# issue ops and a dev-lead-only registry, to exercise the sync-issues blocker path.
_downgrade_sync_stub() {
  _downgrade_stub "$1" "$2" "$3" "$4"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local cut_iso cand_iso base_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Stage timeout (exit code 124)","conclusion":"failure"}]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" \
      --argjson cf "$1" --argjson ct "$2" --argjson bf "$3" --argjson bt "$4" '
      ( [range(0;\$ct)|{databaseId:(2001+.),conclusion:(if . < \$cf then "failure" else "success" end),createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(0;\$bt)|{databaseId:(1001+.),conclusion:(if . < \$bf then "failure" else "success" end),createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  "issue list"*)   echo '[]' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  DG_RINGS="$BATS_TEST_TMPDIR/dg-sync-rings.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$DG_RINGS"
}

@test "orchestrator: sync-issues files a PRE_EXISTING blocker (no needs-human) for an auto-downgraded SUSPECT (#668 inc6)" {
  _downgrade_sync_stub 1 10 1 10
  run env CANARY_RINGS="$DG_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  # Body carries the auto-downgrade note + the candidate-vs-baseline rate comparison.
  grep -q "auto-downgraded" "$ISSUE_LOG"
  grep -q "PRE_EXISTING" "$ISSUE_LOG"
  # Report-only → NOT routed to a human (that is the whole point of the downgrade).
  ! grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

# _downgrade_sync_update_stub — like _downgrade_sync_stub but the issue list returns
# an existing open blocker so the UPDATE path (not CREATE) is exercised.
_downgrade_sync_update_stub() {
  local cand_fail="$1" cand_total="$2" base_fail="$3" base_total="$4"
  _downgrade_stub "$cand_fail" "$cand_total" "$base_fail" "$base_total"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local cut_iso cand_iso base_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Stage timeout (exit code 124)","conclusion":"failure"}]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" \
      --argjson cf "$cand_fail" --argjson ct "$cand_total" --argjson bf "$base_fail" --argjson bt "$base_total" '
      ( [range(0;\$ct)|{databaseId:(2001+.),conclusion:(if . < \$cf then "failure" else "success" end),createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(0;\$bt)|{databaseId:(1001+.),conclusion:(if . < \$bf then "failure" else "success" end),createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  "issue list"*)   echo '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  DG_RINGS="$BATS_TEST_TMPDIR/dg-sync-update-rings.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$DG_RINGS"
}

@test "orchestrator: sync-issues UPDATE path removes needs-human when SUSPECT is auto-downgraded to PRE_EXISTING (#668 inc6)" {
  # Existing open blocker #501 (was SUSPECT, has needs-human). Now auto-downgraded → PRE_EXISTING.
  # The update path must explicitly REMOVE needs-human so stale routing is cleared.
  _downgrade_sync_update_stub 1 10 1 10
  run env CANARY_RINGS="$DG_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated blocker issue #501 for dev-lead"* ]]
  # PRE_EXISTING → must NOT add needs-human
  ! grep -q -- "--add-label needs-human" "$ISSUE_LOG"
  # PRE_EXISTING → must REMOVE needs-human (clear stale routing from the SUSPECT era)
  grep -q -- "--remove-label needs-human" "$ISSUE_LOG"
}

# _downgrade_mixed_stub — two candidate failures: run 2001 is a workload-timeout (suspect
# class match) and run 2002 is an unrelated failure. The baseline has 1 workload-timeout.
# Used to verify that mixed-failure candidates are NOT auto-downgraded (#668 inc6 guard).
_downgrade_mixed_stub() {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso cand_iso base_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run view"*" 2002 "*) echo '{"jobs":[{"steps":[{"name":"Some unrelated test failure","conclusion":"failure"}]}]}' ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Stage timeout (exit code 124)","conclusion":"failure"}]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" '
      ( [{databaseId:2001,conclusion:"failure",createdAt:\$cc,workflowName:"Dev-Lead Agent"},
         {databaseId:2002,conclusion:"failure",createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(0;8)|{databaseId:(2003+.),conclusion:"success",createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [{databaseId:1001,conclusion:"failure",createdAt:\$bb,workflowName:"Dev-Lead Agent"}]
      + [range(0;9)|{databaseId:(1002+.),conclusion:"success",createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "orchestrator: mixed-failure (workload-timeout + unrelated) is NOT auto-downgraded — unrelated failures keep gate SUSPECT (#668 inc6 per-failure attribution guard)" {
  # Candidate: 2 failures — run 2001 (workload-timeout, suspect class, rate OK) +
  # run 2002 (unrelated failure, not suspect-attributed). Even though the workload-timeout
  # rate compares no-worse to baseline, the unrelated failure must block downgrade.
  _downgrade_mixed_stub
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"auto-downgraded"* ]]
  [[ "$output" != *"PRE_EXISTING"* ]]
}

# _downgrade_baseline_incomplete_stub — like _downgrade_stub 1 10 1 10 but the single
# baseline failure (run 1001) returns a non-zero exit from `gh run view`, simulating an
# API error. Used to verify fail-closed behaviour on incomplete baseline evidence (#668 inc6).
_downgrade_baseline_incomplete_stub() {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso cand_iso base_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run view"*" 1001 "*) exit 1 ;;  # simulate API failure for the only baseline failure
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Stage timeout (exit code 124)","conclusion":"failure"}]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" '
      ( [{databaseId:2001,conclusion:"failure",createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(0;9)|{databaseId:(2002+.),conclusion:"success",createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [{databaseId:1001,conclusion:"failure",createdAt:\$bb,workflowName:"Dev-Lead Agent"}]
      + [range(0;9)|{databaseId:(1002+.),conclusion:"success",createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "orchestrator: baseline signature lookup failure → stays SUSPECT (fail-closed on incomplete baseline evidence, #668 inc6)" {
  # Candidate: 1 workload-timeout (rate OK). Baseline: 1 failure but gh run view returns
  # exit 1 for it (API error). Incomplete baseline evidence → must HOLD, not DOWNGRADE.
  _downgrade_baseline_incomplete_stub
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"auto-downgraded"* ]]
  [[ "$output" != *"PRE_EXISTING"* ]]
}

@test "_blocker_body: SUSPECT triage renders the class guidance (discriminating question)" {
  # The blocker body must surface the workload-timeout discriminating question prominently
  # so a human confirm is a fast check, and keep the SUSPECT label + needs-human routing.
  run env CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _blocker_body dev-lead 'next->ring0' cccccccccccc 1 0 SUSPECT petry-projects/.github-private '_(evidence)_'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" == *"needs-human"* ]]
  [[ "$output" == *"override"* ]]   # the guidance names the fast path when unrelated
}

@test "_blocker_body: PRE_EXISTING triage still renders the genuine pre-existing banner" {
  # Regression guard: a real PRE_EXISTING triage must keep its banner + fix-forward note.
  run env CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _blocker_body dev-lead 'next->ring0' cccccccccccc 1 0 PRE_EXISTING petry-projects/.github-private '_(evidence)_'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRE_EXISTING"* ]]
  [[ "$output" == *"byte-identical"* ]]
}

@test "_blocker_body: indeterminate triage (cut date unresolved) does NOT claim PRE_EXISTING" {
  # Fail-closed path (_frontier_state, cut_z empty): state=BLOCKED, triage="-", cum_fail=0.
  # The body must not falsely assert an environmental/byte-identical failure — there is none.
  run env CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _blocker_body ci-failure-analyst 'next->ring0' df3b7d462460 0 0 - petry-projects/.github-private '_(no candidate cut date resolved — cannot list failing runs)_'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PRE_EXISTING"* ]]
  [[ "$output" != *"byte-identical"* ]]
  # It must instead surface the honest reason: an unresolved cut date holding the gate.
  [[ "$output" == *"cut date"* ]]
  [[ "$output" == *"INDETERMINATE"* ]]
}

@test "orchestrator: evaluate warning for a fail-closed frontier does NOT claim PRE_EXISTING" {
  # cmd_evaluate's BLOCKED branch must distinguish triage="-" (cut date unresolved) from a real
  # PRE_EXISTING failure, so the job-log warning is not misleading.
  run env CANARY_RINGS="$RINGS" bash -c '
    source "'"$ORCH"'"
    _frontier_state() { echo "df3b7d462460 ring0 next->ring0 BLOCKED 0 4 0 3 0 0 0 - - - 0 0 0 0"; }
    cmd_evaluate ci-failure-analyst'
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" != *"PRE_EXISTING"* ]]
  [[ "$output" == *"cut date"* ]]
}

# ── sync-issues needs-human label routing for SUSPECT triage ─────────────────────────
# The create path applies needs-human for both REGRESSION and SUSPECT (fixed in 4cd379b).
# The update path must match: when an existing open blocker is refreshed with SUSPECT
# triage, needs-human must be re-applied so escalation routing is not lost on re-runs.
#
# _sync_suspect_stub — like _sync_stub but with differs=1 blobs (reuseAAAA vs reuseBBBB)
# and failure runs whose failed step matches the dev-lead workload-timeout suspect class.
_sync_suspect_stub() {
  local blocker_list="${1:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local cut_iso run_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)    echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)   echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)   echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*)               printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseBBBB" ;;
  *"run list"*) jq -nc --arg d "$run_iso" '[range(3)|{conclusion:"failure",createdAt:\$d,databaseId:88002,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Stage timeout (exit code 124)","conclusion":"failure"}]}]}' ;;
  "issue list"*) echo '$blocker_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  SYNC_RINGS="$BATS_TEST_TMPDIR/sync-rings-suspect.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$SYNC_RINGS"
}

# ── sync-issues fail-closed on partial/failed run-history data (#820) ─────────────────
# sync-issues reads run history through _run_json; on a SUSTAINED fetch failure (#738)
# _frontier_state aborts to empty output under `set -e`, and the agent used to fall into the
# "not BLOCKED" branch — silently skipping (or auto-closing) its regression tracking issue.
# The resilience contract: on a data gap, still determine everything that does NOT need run
# history (candidate/frontier/transition/reusable-differs → triage) and FAIL CLOSED to a
# tracked BLOCKED issue with the gap annotated. A TOTAL inability (not even candidate/frontier
# resolvable) stays a hard error (non-zero), never a green no-op.
#
# _sync_gap_stub — like _sync_stub but `gh run list` FAILS every attempt (the fetch outage),
# while tag/blob resolution stays intact and the candidate's reusable DIFFERS from the prior
# channel (ref=cccc vs ref=bbbb blobs differ → differs=1 → REGRESSION fail-closed triage).
_sync_gap_stub() {
  # Thin wrapper: delegates to _sync_stub with gap mode (run list always fails) and differing
  # blobs (ref=cccc vs ref=bbbb are distinct, so reusable-differs=1 → REGRESSION fail-closed).
  local blocker_list="${1:-[]}"
  _sync_stub "gap" "$blocker_list" "differ"
  SYNC_RINGS="$BATS_TEST_TMPDIR/sync-rings-gap.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$SYNC_RINGS"
}

@test "orchestrator: sync-issues fails CLOSED on a partial run-history fetch — opens a REGRESSION needs-human blocker with the gap annotated (#820)" {
  # The run-history fetch is down but tags/blobs resolve and the reusable DIFFERS → the gate
  # cannot confirm health but MUST NOT report a false all-clear: it fails closed to a tracked
  # BLOCKED issue, triage REGRESSION (fail-closed), routed to dev-lead + needs-human.
  _sync_gap_stub '[]'
  local summ="$BATS_TEST_TMPDIR/summary_gap.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" \
      CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 GITHUB_STEP_SUMMARY="$summ" \
      bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  # A blocker issue is OPENED (never silently skipped) and routed for action + human review.
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  grep -q '^CREATE|' "$ISSUE_LOG"
  grep -q -- "--add-label dev-lead" "$ISSUE_LOG"
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
  # The created issue body annotates the data gap so a human knows counts are unreliable.
  grep -q "PARTIAL DATA" "$ISSUE_LOG"
  grep -qi "run.history" "$ISSUE_LOG"
  # The fleet dashboard still renders.
  grep -q "Canary Rollout — fleet status" "$summ"
}

@test "orchestrator: sync-issues partial-fetch UPDATE keeps an existing regression's issue open (no auto-close) (#820)" {
  # An OPEN blocker exists for dev-lead. A fetch outage must NOT be read as 'cleared' and close
  # it — it must be UPDATED (kept open) and re-annotated with the gap.
  _sync_gap_stub '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" \
      CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated blocker issue #501 for dev-lead"* ]]
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
  # It must NOT have been auto-closed by the fetch outage.
  ! grep -q "^CLOSE|" "$ISSUE_LOG"
}

@test "orchestrator: _frontier_state_resilient tags a normal state line with datagap=0 and passes it through (#820)" {
  # When _frontier_state resolves normally the wrapper is transparent: same fields, trailing 0.
  run bash -c "source '$ORCH'; _frontier_state() { echo 'ccccccc ring0 next->ring0 BLOCKED 0 4 0 3 2 0 0 REGRESSION - - 0 0 0 0'; }; _frontier_state_resilient dev-lead"
  [ "$status" -eq 0 ]
  [[ "$output" == "ccccccc ring0 next->ring0 BLOCKED 0 4 0 3 2 0 0 REGRESSION - - 0 0 0 0 0" ]]
}

@test "orchestrator: _frontier_state_resilient keeps an unresolvable (empty) src commit tracked BLOCKED with triage PRE_EXISTING — unchanged by the pair_verdict refactor (#1242)" {
  # A run-history fetch failure (data gap) makes the fallback walk the rings itself. ring0 has no tag but ring1 does:
  # the pair is still pending (never vanishes), and with no resolvable candidate the reusable cannot
  # differ, so classify_failure reads it as PRE_EXISTING — exactly as before the refactor.
  run bash -c "source '$ORCH'; _frontier_state() { echo org/x >> \"\$_CANARY_FETCH_FAIL_FLAG\"; return 1; }
    ordered_channels() { echo 'next,ring0,ring1'; }
    _ring_commits() { printf 'next - 0\nring0 - 0\nring1 abc1234 0\n'; }
    _frontier_state_resilient dev-lead 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *" ring1 ring0->ring1 BLOCKED "*" PRE_EXISTING "* ]]
}

@test "orchestrator: _frontier_state_resilient fails CLOSED (non-zero) on a TOTAL inability to determine state (#820)" {
  # _frontier_state aborts to empty AND the candidate/frontier cannot be re-resolved from tags:
  # a total inability must stay a HARD ERROR (non-zero), never a green no-op.
  run bash -c "source '$ORCH'; _frontier_state() { return 1; }; channel_commit() { echo ''; }; ordered_channels() { echo 'next,ring0,ring1,stable'; }; _frontier_state_resilient dev-lead"
  [ "$status" -ne 0 ]
}

@test "orchestrator: sync-issues ends NON-ZERO when an agent's state is totally undeterminable (fail-closed, not a green no-op) (#820)" {
  # Force a total inability for the single registered agent and assert the step fails closed.
  _sync_gap_stub '[]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" \
      CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 bash -c "
        source '$ORCH'
        _frontier_state_resilient() { return 1; }
        cmd_sync_issues
      "
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot determine canary state"* ]]
}

@test "orchestrator: sync-issues CREATE path applies needs-human for SUSPECT triage" {
  # No existing issue → create path; SUSPECT (differs=1 + suspect step) must add needs-human.
  _sync_suspect_stub '[]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

@test "orchestrator: sync-issues UPDATE path applies needs-human for SUSPECT triage" {
  # Existing open blocker #501 → update path; SUSPECT triage must still add needs-human.
  # The create path was fixed in 4cd379b; this test pins the update-path parity contract.
  _sync_suspect_stub '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated blocker issue #501 for dev-lead"* ]]
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

# ── AWAITING_CONFIRMATION: opt-in human go/no-go at ring1->stable (#668 increment 3, #677) ─
# Layer 3 of the #668 design. A correctness-sensitive agent (dev-lead) flagged
# require_confirmation on its ring1->stable transition holds in AWAITING_CONFIRMATION once
# reliability PASSES: the scheduled promote-all never auto-advances it; a deliberate
# `promote <agent> --confirm` dispatch (the confirmation IS the dispatch — no state store)
# clears it. `--confirm` is NOT `--override`: it advances ONLY a reliability-clean
# AWAITING_CONFIRMATION state and can never bypass a BLOCKED gate. sync-issues files an
# evidence-carrying `canary-confirm` issue (compare diff link; needs-human). Default-absent
# (transition without the key) = fully autonomous, byte-identical for opted-out agents.

@test "canary-rings.json: dev-lead ring1->stable opts into require_confirmation; opted-out agents default-off" {
  run jq -e '.agents["dev-lead"].gate.transitions["ring1->stable"].require_confirmation == true' "$RINGS"
  [ "$status" -eq 0 ]
  # Every OTHER agent's ring1->stable must NOT carry the key (absent → today's autonomous behaviour).
  run jq -e '[.agents | to_entries[] | select(.key != "dev-lead")
             | .value.gate.transitions["ring1->stable"].require_confirmation] | all(. == null)' "$RINGS"
  [ "$status" -eq 0 ]
}

# _confirm_stub <conclusion> <reusable_diff> [failed_step] — dev-lead (cross-repo) laid out with
# next/ring0/ring1 = candidate (cccc) and stable = prior (bbbb): frontier = stable, transition
# ring1->stable (which opts into require_confirmation). cut 2 days ago (dwell >> 12h), runs 1 day
# ago. conclusion=success + reusable_diff=0 → reliability PROMOTE → overlaid to AWAITING_CONFIRMATION;
# conclusion=failure + reusable_diff=1 + a non-suspect step → BLOCKED + REGRESSION.
_confirm_stub() {
  local conclusion="${1:-success}" reusable_diff="${2:-0}" failed_step="${3:-Compile TypeScript}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso run_iso cand_blob="reuseAAAA" prior_blob="reuseAAAA"
  [ "$reusable_diff" = "1" ] && prior_blob="reuseBBBB"
  cut_iso="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)    echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/stable"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*)               printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "$cand_blob" ;;
  *"ref=bbbb"*) echo "$prior_blob" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d,databaseId:88003,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) jq -nc --arg s "$failed_step" '{jobs:[{steps:[{name:\$s,conclusion:"failure"}]}]}' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api above
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: reliability PROMOTE at ring1->stable holds as AWAITING_CONFIRMATION (not PROMOTE)" {
  # Clean window, dwell >> 12h, sample >= 1 → reliability PROMOTE — but require_confirmation
  # overlays it to AWAITING_CONFIRMATION so the scheduled sweep will not auto-advance.
  _confirm_stub success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"ring1->stable"* ]]
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
  [[ "$output" == *"--confirm"* ]]   # the report names the exact clearing action
}

@test "orchestrator: AWAITING_CONFIRMATION does NOT advance without --confirm (scheduled sweep holds)" {
  # promote with no flags (the promote-all sweep forwards none) must NOT move the tag.
  _confirm_stub success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
  [[ "$output" != *"DRY-RUN"* ]]     # no move planned — held for confirmation
  [[ "$output" == *"--confirm"* ]]   # tells the human how to confirm
}

@test "orchestrator: promote --confirm advances a reliability-clean AWAITING_CONFIRMATION frontier" {
  _confirm_stub success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --confirm --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]         # the move IS planned once confirmed
  [[ "$output" == *"stable"* ]]
  [[ "$output" == *"gh api PATCH"* ]]
}

@test "orchestrator: --confirm is NOT --override — it cannot advance a BLOCKED gate" {
  # A real regression (failure + differs=1, non-suspect step) is BLOCKED+REGRESSION. --confirm
  # must refuse it: confirmation only clears a reliability-clean AWAITING_CONFIRMATION state.
  _confirm_stub failure 1 "Compile TypeScript"
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote dev-lead --confirm --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"REGRESSION"* ]]
  [[ "$output" != *"DRY-RUN"* ]]     # no move — --confirm did not bypass reliability
}

@test "_confirm_body: renders the compare diff link + the promote --confirm instruction" {
  run env CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _confirm_body dev-lead 'ring1->stable' cccccccccccc bbbbbbbbbbbb petry-projects/.github-private 5 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"canary-confirm:dev-lead"* ]]                              # idempotency marker
  [[ "$output" == *"compare/bbbbbbbbbbbb...cccccccccccc"* ]]                  # stable -> candidate diff
  [[ "$output" == *"--confirm"* ]]                                           # the go action
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
}

@test "_confirm_body: gracefully handles empty prior (no prior stable release)" {
  run env CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _confirm_body dev-lead 'ring1->stable' cccccccccccc '' petry-projects/.github-private 5 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"canary-confirm:dev-lead"* ]]
  [[ "$output" == *"(no prior stable release)"* ]]                           # fallback diff link
  [[ "$output" != *"compare/..."* ]]                                         # no broken URL
  [[ "$output" == *"none"* ]]                                                # fallback display_prior
}

# _confirm_sync_stub <issue_list_json> — dev-lead-only sync fixture at the ring1->stable frontier
# (next/ring0/ring1 = cand, stable = prior), clean success runs → AWAITING_CONFIRMATION; logs
# every gh issue op to ISSUE_LOG so a test can assert the confirmation-issue upsert.
_confirm_sync_stub() {
  local issue_list="${1:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local cut_iso run_iso
  cut_iso="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)    echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/stable"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*)               printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseAAAA" ;;
  *"run list"*) jq -nc --arg d "$run_iso" '[range(20)|{conclusion:"success",createdAt:\$d,databaseId:88004,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) echo '{"jobs":[{"steps":[]}]}' ;;
  "issue list"*) echo '$issue_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  SYNC_RINGS="$BATS_TEST_TMPDIR/sync-rings-confirm.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$SYNC_RINGS"
}

@test "orchestrator: sync-issues opens a canary-confirm issue for an AWAITING_CONFIRMATION agent" {
  _confirm_sync_stub '[]'
  local summ="$BATS_TEST_TMPDIR/summary-confirm.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened confirm issue #777 for dev-lead"* ]]
  # A SEPARATE issue keyed by the canary-confirm label + marker (not the blocker issue).
  grep -q -- "--label canary-confirm" "$ISSUE_LOG"
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
  grep -q "compare/" "$ISSUE_LOG"                       # evidence: the stable -> candidate diff link
  grep -q "AWAITING_CONFIRMATION" "$summ"               # the fleet dashboard surfaces the new state
}

@test "orchestrator: sync-issues auto-closes a stale canary-confirm issue once the agent is no longer awaiting" {
  # dev-lead is at next->ring0 (PROMOTE, NOT require_confirmation) but an OPEN confirm issue
  # #502 lingers → it must be closed (the go/no-go no longer applies).
  _sync_stub success '[{"number":502,"state":"OPEN","body":"<!-- canary-confirm:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed cleared confirm issue #502 for dev-lead"* ]]
  grep -q "CLOSE|.*502" "$ISSUE_LOG"
}

# ── #1118: independent per-pair evaluation — a ring1->stable hold survives newer cuts ──
# Before #1118 `_frontier_state` evaluated ONLY next's candidate at a SINGLE frontier: once
# autocut moved `next`, the frontier fell back to ring0 and a pending ring1->stable
# AWAITING_CONFIRMATION hold vanished (its canary-confirm issue auto-closed, unconfirmed). Now
# EVERY adjacent src->dst pair is evaluated independently on the commit currently sitting on
# `src`, so several transitions can be in flight at once and an older ring1 candidate keeps its
# human go/no-go regardless of newer cuts landing on next/ring0.
#
# _multicand_stub <t_next> <t_ring0> <t_ring1> <t_stable> <off_c1> <off_c2> <off_c3> [fail_sub] [differ] [issue_list]
#   t_* ∈ {C1,C2,C3,PRIOR,NONE,ERR} — the commit each tier carries (C1=cccc…, C2=dddd…, C3=eeee…,
#   PRIOR=bbbb…); NONE = the tag is genuinely absent (404), ERR = its lookup errors (5xx, #1225). off_cN — cut age (a `date -d` offset string, e.g. "1 hours"/"3 days") of the
#   release tag for C1/C2/C3. fail_sub — a repo substring whose `run list` returns FAILURES
#   (default: none → all clean). differ="C1" makes C1's reusable blob differ from the prior
#   (default: all identical → differs=0). issue_list — JSON returned by `gh issue list`.
#   dev-lead is cross-repo (GITHUB_REPOSITORY=.github forces THIS_REPO=.github): all tag/blob/
#   release resolution goes via gh api. Sets MC_RINGS (dev-lead-only registry); logs issue ops
#   to ISSUE_LOG.
_multicand_stub() {
  local t_next="$1" t_ring0="$2" t_ring1="$3" t_stable="$4"
  local off1="$5" off2="$6" off3="$7" fail_sub="${8:-__NEVER_FAIL__}" differ="${9:-}" issue_list="${10:-[]}"
  local C1="cccccccccccccccccccccccccccccccccccccccc"
  local C2="dddddddddddddddddddddddddddddddddddddddd"
  local C3="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  local PRIOR="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local -A M=( [C1]="$C1" [C2]="$C2" [C3]="$C3" [PRIOR]="$PRIOR" [NONE]="" [ERR]="ERR" )
  local n="${M[$t_next]}" r0="${M[$t_ring0]}" r1="${M[$t_ring1]}" st="${M[$t_stable]}"
  local blob_c1="reuseSAME"; [ "$differ" = "C1" ] && blob_c1="reuseCAND"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  local c1_iso c2_iso c3_iso run_iso
  c1_iso="$(date -u -d "-$off1" +%Y-%m-%dT%H:%M:%SZ)"
  c2_iso="$(date -u -d "-$off2" +%Y-%m-%dT%H:%M:%SZ)"
  c3_iso="$(date -u -d "-$off3" +%Y-%m-%dT%H:%M:%SZ)"
  run_iso="$(date -u -d '-12 hours' +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob/release resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
# NONE = genuinely absent (HTTP 404, as the real API reports it); ERR = a lookup ERROR (HTTP 502).
_ref() {
  case "\$1" in
    "")  echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    ERR) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
    *)   echo "\$1 commit" ;;
  esac
}
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   _ref "$n" ;;
  *"git/ref/tags/dev-lead/ring0"*)  _ref "$r0" ;;
  *"git/ref/tags/dev-lead/ring1"*)  _ref "$r1" ;;
  *"git/ref/tags/dev-lead/stable"*) _ref "$st" ;;
  *"matching-refs/tags/dev-lead/v"*)
    printf 'refs/tags/dev-lead/v2.2.0\tobjC1\ttag\n'
    printf 'refs/tags/dev-lead/v2.1.0\tobjC2\ttag\n'
    printf 'refs/tags/dev-lead/v2.0.0\tobjC3\ttag\n' ;;
  *"git/tags/objC1"*) printf '%s\t%s\n' "$C1" "$c1_iso" ;;
  *"git/tags/objC2"*) printf '%s\t%s\n' "$C2" "$c2_iso" ;;
  *"git/tags/objC3"*) printf '%s\t%s\n' "$C3" "$c3_iso" ;;
  *"ref=cccc"*) echo "$blob_c1" ;;
  *"ref=dddd"*) echo "reuseSAME" ;;
  *"ref=eeee"*) echo "reuseSAME" ;;
  *"ref=bbbb"*) echo "reuseSAME" ;;
  *"run list"*)
    __c=success
    case "\$*" in *"$fail_sub"*) __c=failure ;; esac
    jq -nc --arg d "$run_iso" --arg c "\$__c" '[range(20)|{conclusion:\$c,createdAt:\$d,databaseId:88010,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Compile TypeScript","conclusion":"failure"}]}]}' ;;
  "issue list"*) echo '$issue_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/909" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  MC_RINGS="$BATS_TEST_TMPDIR/mc-rings.json"
  jq '{org_infra_repos, agents: {"dev-lead": .agents["dev-lead"]}}' "$RINGS" > "$MC_RINGS"
}

@test "#1118: a newer next cut does NOT drop a pending ring1->stable AWAITING_CONFIRMATION hold" {
  # next=C1 cut 1h ago (next->ring0 SOAKING), ring0=ring1=C3 cut 30h ago, stable=prior.
  # ring1->stable must STILL be evaluated as AWAITING_CONFIRMATION even though `next` moved.
  _multicand_stub C1 C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"ring1->stable"* ]]
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
  # the newer next candidate is independently in flight, still soaking (it does NOT cancel the hold)
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"SOAKING"* ]]
}

@test "#1118: sync-issues KEEPS (updates, not closes) the ring1-candidate confirm issue across a newer next cut" {
  # An OPEN canary-confirm issue already exists keyed on ring1's candidate C3. A newer next cut
  # (C1) must NOT close it — the hold is keyed on the ring1 candidate, which is unchanged (AC3/AC7a).
  _multicand_stub C1 C3 C3 PRIOR "1 hours" "3 days" "30 hours" "" "" \
    '[{"number":901,"state":"OPEN","body":"<!-- canary-confirm:dev-lead:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee -->"}]'
  local summ="$BATS_TEST_TMPDIR/mc-a.md"; : > "$summ"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  grep -q "EDIT|.*901" "$ISSUE_LOG"          # the C3 confirm issue is refreshed, not closed
  run grep -q "CLOSE|.*901" "$ISSUE_LOG"      # the hold survived the newer next cut
  [ "$status" -eq 1 ]                         # (exactly 1: a missing log, status 2, must not pass)
  grep -q "AWAITING_CONFIRMATION" "$summ"
}

@test "#1118: promote --confirm advances stable to ring1's candidate while next->ring0 keeps soaking" {
  # next=C1 (soaking), ring0=ring1=C3 (AWAITING at ring1->stable). --confirm clears ONLY the
  # ring1->stable hold; the newer, still-soaking next candidate is untouched (AC4/AC7b).
  _multicand_stub C1 C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --confirm --dry-run
  [ "$status" -eq 0 ]
  # stable advances to ring1's candidate (C3 = eeee…), confirmed
  [[ "$output" == *"tags/dev-lead/stable sha=eeeeeeeeeeee"* ]]
  # next->ring0 (the newer candidate) is still soaking — never advanced by --confirm
  [[ "$output" == *"SOAKING"* ]]
  [[ "$output" != *"tags/dev-lead/ring0 sha="* ]]
}

@test "#1118: no tier skip — ring1 only ever advances to the commit currently on ring0" {
  # next=C1, ring0=C2, ring1=C3, stable=prior; every pair clean and old enough to PROMOTE.
  _multicand_stub C1 C2 C3 PRIOR "3 days" "40 hours" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --dry-run
  [ "$status" -eq 0 ]
  # ring0 advances to next's commit (C1 = cccc…)
  [[ "$output" == *"tags/dev-lead/ring0 sha=cccccccccccc"* ]]
  # ring1 advances to ring0's OLD commit (C2 = dddd…) — NEVER skips to next's (C1)
  [[ "$output" == *"tags/dev-lead/ring1 sha=dddddddddddd"* ]]
  [[ "$output" != *"tags/dev-lead/ring1 sha=cccc"* ]]
  # ring1->stable holds for human confirmation (require_confirmation; no --confirm passed)
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
}

@test "#1118: a BLOCKED lower pair does not block an independently clean higher pair" {
  # next=C1 with a REGRESSION on the next tier (reusable differs + a failure there);
  # ring0=ring1=C3 independently clean → ring1->stable is AWAITING, unblocked by the lower pair.
  _multicand_stub C1 C3 C3 PRIOR "3 days" "3 days" "30 hours" "petry-projects/.github-private" C1
  local summ="$BATS_TEST_TMPDIR/mc-d.md"; : > "$summ"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  # lower pair blocked → its canary-blocker issue opens (REGRESSION at next->ring0)
  [[ "$output" == *"opened blocker issue"* ]]
  grep -q "REGRESSION" "$summ"
  # higher pair independently clean → its canary-confirm issue opens (AWAITING at ring1->stable)
  [[ "$output" == *"confirm issue"* ]]
  grep -q "AWAITING_CONFIRMATION" "$summ"
}

@test "#1118: --override advances ONLY the lowest pending pair — never an AWAITING_CONFIRMATION pair for another candidate" {
  # next=C1 BLOCKED (REGRESSION), ring0=ring1=C3 AWAITING at ring1->stable. An operator --override of
  # the blocked newest candidate must not also push stable past the human go/no-go (#668 L3 stays).
  _multicand_stub C1 C3 C3 PRIOR "3 days" "3 days" "30 hours" "petry-projects/.github-private" C1
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --override --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"tags/dev-lead/ring0 sha=cccccccccccc"* ]]     # the overridden lowest pair advances
  [[ "$output" != *"tags/dev-lead/stable sha="* ]]                 # the higher pair keeps its own gate
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
}

@test "#1118: an UNRESOLVABLE source commit with a populated destination fails closed (BLOCKED), never a false COMPLETE" {
  # next has no resolvable tag but ring0 does: next->ring0 is pending and must hold BLOCKED.
  _multicand_stub NONE C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" != *"fully rolled out"* ]]
}

@test "#1118: an unresolvable source commit is a held pair that sync-issues SEES (sentinel, not a shifted blank field)" {
  # next has no resolvable tag: the pair record must still parse (a leading blank field would shift
  # every field, hiding BLOCKED), so sync-issues opens its blocker issue.
  _multicand_stub NONE C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  local summ="$BATS_TEST_TMPDIR/mc-n.md"; : > "$summ"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue"* ]]
  grep -q "BLOCKED" "$summ"
}

@test "#1118: promote --override never acts on an unresolvable candidate (no tag is moved to a sentinel)" {
  _multicand_stub NONE C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --override --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"unresolvable"* ]]
  [[ "$output" != *"tags/dev-lead/ring0 sha=-"* ]]
  [[ "$output" != *"advancing dev-lead/ring0 -> -"* ]]
}

@test "#1118: a lower ring whose tag is UNRESOLVABLE stays in scope — its failures still block a higher pair (fail closed)" {
  # ring0 has no resolvable tag and its member (.github) is failing; ring1->stable must not shed
  # those failures just because ring0's commit is unknown rather than provably different.
  _multicand_stub C1 NONE C3 PRIOR "3 days" "3 days" "30 hours" "repo petry-projects/.github --workflow"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ring1->stable]: BLOCKED"* ]]
}

# ── #1225: a tag-lookup ERROR is unknown, not absent — a lookup outage never reads as COMPLETE ──
# _gh_tag_commit used to return empty for ANY failure, so when every ring lookup errored all rings
# compared equal ("" == "") and _frontier_state emitted COMPLETE: an in-flight rollout reported
# "fully rolled out", sync-issues closed open blockers, promote-all found nothing to promote. A
# genuinely ABSENT tag (404) keeps the legacy behaviour (#1118 AC6); an ERRORED lookup holds every
# pair touching that ring BLOCKED, and sync-issues fails closed (non-zero), as for a run-history outage.

@test "#1225: _gh_tag_commit — an absent tag (404) is empty and NOT recorded as a lookup error" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  # the tag ref 404s, but the host repo itself stays readable (so the 404 is a genuine absence)
  printf '#!/usr/bin/env bash\ncase "$*" in *git/ref/tags/*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;; *) echo petry-projects/.github ;; esac\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  local flag="$BATS_TEST_TMPDIR/tagfail"; : > "$flag"
  run env PATH="$STUB_BIN:$PATH" _CANARY_TAG_FAIL_FLAG="$flag" bash -c "source '$ORCH'; _gh_tag_commit petry-projects/.github dev-lead/next"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$flag" ]
}

@test "#1225: _gh_tag_commit — a 404 on an UNREADABLE host repo is a lookup error, not an absent tag" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  printf '#!/usr/bin/env bash\necho "gh: Not Found (HTTP 404)" >&2; exit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  local flag="$BATS_TEST_TMPDIR/tagfail"; : > "$flag"
  run env PATH="$STUB_BIN:$PATH" _CANARY_TAG_FAIL_FLAG="$flag" bash -c "source '$ORCH'; _gh_tag_commit petry-projects/.github dev-lead/next 2>/dev/null"
  [ "$status" -eq 0 ]
  grep -q "dev-lead/next" "$flag"
}

@test "#1225: _gh_tag_commit — only an explicit HTTP 404 is absence ('not found' text without 404 is an error)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  printf '#!/usr/bin/env bash\necho "gh: repository not found (HTTP 500)" >&2; exit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  local flag="$BATS_TEST_TMPDIR/tagfail"; : > "$flag"
  run env PATH="$STUB_BIN:$PATH" _CANARY_TAG_FAIL_FLAG="$flag" bash -c "source '$ORCH'; _gh_tag_commit petry-projects/.github dev-lead/next 2>/dev/null"
  [ "$status" -eq 0 ]
  grep -q "dev-lead/next" "$flag"
}

@test "#1225: a lookup error whose flag write FAILS still reads as unknown in _ring_commits" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  printf '#!/usr/bin/env bash\necho "gh: Server Error (HTTP 502)" >&2; exit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env PATH="$STUB_BIN:$PATH" _CANARY_TAG_FAIL_FLAG="/nonexistent-dir/flag" bash -c "source '$ORCH'; _gh_tag_commit petry-projects/.github dev-lead/next 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"!tag-lookup-error-unrecorded"* ]]
}

@test "#1225: _gh_tag_commit — a lookup ERROR (5xx) is empty but RECORDED, so callers can tell it from absent" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  printf '#!/usr/bin/env bash\necho "gh: Server Error (HTTP 502)" >&2; exit 1\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  local flag="$BATS_TEST_TMPDIR/tagfail"; : > "$flag"
  run env PATH="$STUB_BIN:$PATH" _CANARY_TAG_FAIL_FLAG="$flag" bash -c "source '$ORCH'; _gh_tag_commit petry-projects/.github dev-lead/next 2>/dev/null"
  [ "$status" -eq 0 ]          # never fails the caller (every other call site keeps working)
  [ -z "$output" ]
  grep -q "dev-lead/next" "$flag"
}

@test "#1225: _gh_tag_commit — a failed annotated-tag DEREF is an error too (the ref exists)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"git/ref/tags/"*) printf 'tagobj\ttag\n' ;;
  *) echo "gh: Server Error (HTTP 503)" >&2; exit 1 ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  local flag="$BATS_TEST_TMPDIR/tagfail"; : > "$flag"
  run env PATH="$STUB_BIN:$PATH" _CANARY_TAG_FAIL_FLAG="$flag" bash -c "source '$ORCH'; _gh_tag_commit petry-projects/.github dev-lead/ring0 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "dev-lead/ring0" "$flag"
}

@test "#1225: a TOTAL tag-lookup outage holds BLOCKED and NEVER reports fully rolled out" {
  _multicand_stub ERR ERR ERR ERR "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"[next->ring0]: BLOCKED"* ]]
  [[ "$output" == *"[ring0->ring1]: BLOCKED"* ]]
  [[ "$output" == *"[ring1->stable]: BLOCKED"* ]]
  [[ "$output" != *"COMPLETE"* ]]
  [[ "$output" != *"fully rolled out"* ]]
}

@test "#1225: a TOTAL tag-lookup outage — promote moves nothing and does not report nothing-to-promote" {
  _multicand_stub ERR ERR ERR ERR "3 days" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" != *"fully rolled out"* ]]
  [[ "$output" != *"nothing to promote"* ]]
  [[ "$output" != *"tags/dev-lead/"*" sha="* ]]
}

@test "#1225: a TOTAL tag-lookup outage — promote --override still moves nothing" {
  _multicand_stub ERR ERR ERR ERR "3 days" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --override --dry-run
  [[ "$output" == *"a ring tag lookup errored; not promoting"* ]]
  [[ "$output" != *"advancing dev-lead"* ]]
  [[ "$output" != *"tags/dev-lead/"*" sha="* ]]
}

@test "#1225: sync-issues FAILS CLOSED on a total tag-lookup outage — non-zero, and closes neither blocker nor confirm issue" {
  _multicand_stub ERR ERR ERR ERR "1 hours" "3 days" "30 hours" "" "" \
    '[{"number":905,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"},{"number":906,"state":"OPEN","body":"<!-- canary-confirm:dev-lead:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee -->"}]'
  local summ="$BATS_TEST_TMPDIR/tg-a.md"; : > "$summ"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag lookup"* ]]
  grep -q "EDIT|.*905" "$ISSUE_LOG"          # the open blocker is refreshed (held), never closed
  run grep -q "CLOSE|" "$ISSUE_LOG"           # no issue is closed on the strength of an outage
  [ "$status" -eq 1 ]
  grep -q '| `dev-lead` | BLOCKED |' "$summ"
  run grep -qF '| `dev-lead` | COMPLETE |' "$summ"
  [ "$status" -eq 1 ]
}

@test "#1225: every tag genuinely ABSENT (404) keeps the legacy COMPLETE (#1118 AC6)" {
  _multicand_stub NONE NONE NONE NONE "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"fully rolled out"* ]]
  [[ "$output" != *"BLOCKED"* ]]
}

@test "#1225: sync-issues on an all-ABSENT (unseeded/legacy) agent is a clean COMPLETE, exit 0" {
  _multicand_stub NONE NONE NONE NONE "1 hours" "3 days" "30 hours"
  local summ="$BATS_TEST_TMPDIR/tg-b.md"; : > "$summ"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  grep -qF '| `dev-lead` | COMPLETE |' "$summ"
  run grep -q "CREATE|" "$ISSUE_LOG"          # no blocker opened for an agent with no tags yet
  [ "$status" -eq 1 ]
}

@test "#1225: a single ERRORED lookup holds only the pair touching that ring; other pairs evaluate normally" {
  # next errors; ring0=ring1=C3 (cut 30h) and stable=prior → ring1->stable is independently
  # AWAITING_CONFIRMATION exactly as in the all-resolved case; only next->ring0 is held.
  _multicand_stub ERR C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"[next->ring0]: BLOCKED"* ]]
  [[ "$output" == *"[ring1->stable]: AWAITING_CONFIRMATION"* ]]
  [[ "$output" != *"[ring0->ring1]"* ]]
}

@test "#1225: an ERRORED destination lookup holds that pair — never PROMOTEs onto an unknown ring" {
  # stable errors; next=C1 clean and old enough to PROMOTE into ring0, which must still advance.
  _multicand_stub C1 C3 C3 ERR "3 days" "3 days" "30 hours"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" bash "$ORCH" promote dev-lead --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"tags/dev-lead/ring0 sha=cccccccccccc"* ]]
  [[ "$output" != *"tags/dev-lead/stable sha="* ]]
  [[ "$output" == *"ring1->stable"*"BLOCKED"* ]]
}

@test "#1225: sync-issues opens a tag-lookup blocker for a single errored pair and still exits non-zero" {
  _multicand_stub ERR C3 C3 PRIOR "1 hours" "3 days" "30 hours"
  local summ="$BATS_TEST_TMPDIR/tg-c.md"; : > "$summ"
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$MC_RINGS" ISSUE_REPO="petry-projects/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 1 ]
  [[ "$output" == *"opened blocker issue"* ]]
  grep -q "CREATE|.*tag lookup failed" "$ISSUE_LOG"
  grep -q "AWAITING_CONFIRMATION" "$summ"     # the unaffected higher pair is still tracked normally
}

# The confirm issue's idempotency marker is keyed on the ring1 CANDIDATE (#1118 AC3), so a
# recut ring1 candidate does not silently transfer a human's pending go/no-go to a new commit.
@test "#1118: _confirm_body keys the canary-confirm marker on agent AND candidate" {
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _confirm_body dev-lead 'ring1->stable' cafe1234cafe bbbbbbbbbbbb petry-projects/.github-private 5 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!-- canary-confirm:dev-lead:cafe1234cafe -->"* ]]
}

# ── #668 increment 4 (Layer 2): decision telemetry — pure core + engine overlay ──
# decision_class(): the taken `decision: <class>` no-op step (skipped branches ignored, prefix
# stripped) off a `gh run view --json jobs` payload. decide_decision_shift(): the pure gate over
# a candidate vs prior-version decision-mix. Both are pure (no gh/git) → sourced $LIB, no stubs.
@test "decision_class: returns the taken decision (skipped branches ignored, prefix stripped)" {
  json='{"jobs":[{"steps":[
    {"name":"Resolve PR URL","conclusion":"success"},
    {"name":"decision: dispatched","conclusion":"skipped"},
    {"name":"decision: skip-draft","conclusion":"skipped"},
    {"name":"decision: skip-checks-pending","conclusion":"success"}
  ]}]}'
  [ "$(decision_class 'decision: ' "$json")" = "skip-checks-pending" ]
}
@test "decision_class: a run with no decision step → empty (degrades to INSUFFICIENT upstream)" {
  [ "$(decision_class 'decision: ' '{"jobs":[{"steps":[{"name":"Build","conclusion":"success"}]}]}')" = "" ]
}
@test "decision_class: empty / absent / non-object json → empty (never errs)" {
  [ "$(decision_class 'decision: ' '')" = "" ]
  [ "$(decision_class 'decision: ' '{}')" = "" ]
  [ "$(decision_class 'decision: ' 'not json')" = "" ]
}

DECISION_KNOBS='{"min_candidate_sample":10,"min_baseline_sample":20,"max_shift_permille":400}'
@test "decide_decision_shift: a gross share move ≥ threshold → SHIFT" {
  # candidate is all skip-checks-pending (0‰ dispatched) vs an all-dispatched baseline → 1000‰ move
  [ "$(decide_decision_shift '{"skip-checks-pending":12}' '{"dispatched":22}' "$DECISION_KNOBS")" = "SHIFT" ]
}
@test "decide_decision_shift: shares within threshold → OK (no effect)" {
  # ~917‰/83‰ vs ~909‰/91‰ dispatched/skip-draft — max per-class delta 8‰ ≪ 400‰
  [ "$(decide_decision_shift '{"dispatched":11,"skip-draft":1}' '{"dispatched":20,"skip-draft":2}' "$DECISION_KNOBS")" = "OK" ]
}
@test "decide_decision_shift: a move exactly at max_shift_permille → SHIFT (inclusive)" {
  # 500‰ dispatched (cand) vs 900‰ (base) → delta 400‰ == threshold
  [ "$(decide_decision_shift '{"dispatched":10,"skip-draft":10}' '{"dispatched":18,"skip-draft":2}' "$DECISION_KNOBS")" = "SHIFT" ]
}
@test "decide_decision_shift: candidate below min_candidate_sample → INSUFFICIENT" {
  [ "$(decide_decision_shift '{"dispatched":5}' '{"dispatched":22}' "$DECISION_KNOBS")" = "INSUFFICIENT" ]
}
@test "decide_decision_shift: baseline below min_baseline_sample → INSUFFICIENT" {
  [ "$(decide_decision_shift '{"dispatched":12}' '{"dispatched":5}' "$DECISION_KNOBS")" = "INSUFFICIENT" ]
}
@test "decide_decision_shift: empty / unparseable side → INSUFFICIENT (no decision steps to compare)" {
  [ "$(decide_decision_shift '{}' '{"dispatched":22}' "$DECISION_KNOBS")" = "INSUFFICIENT" ]
  [ "$(decide_decision_shift '{"dispatched":12}' '' "$DECISION_KNOBS")" = "INSUFFICIENT" ]
  [ "$(decide_decision_shift 'garbage' '{"dispatched":22}' "$DECISION_KNOBS")" = "INSUFFICIENT" ]
}

@test "canary-rings.json: pr-auto-review opts into gate.correctness (#668 L2); no other agent does" {
  run jq -e '.agents["pr-auto-review"].gate.correctness | .decision_step_prefix=="decision: " and .min_candidate_sample==10 and .min_baseline_sample==20 and .max_shift_permille==400' "$RINGS"
  [ "$status" -eq 0 ]
  # default-off everywhere else: pr-auto-review is the ONLY agent carrying a correctness block
  run bash -c "jq -r '[.agents|to_entries[]|select(.value.gate.correctness)|.key]|sort|join(\",\")' '$RINGS'"
  [ "$output" = "pr-auto-review" ]
}

# The reusable emits one `decision: <class>` no-op step per outcome branch — the engine reads
# their names off `gh run view --json jobs` (decision_class). Structural guard on the workflow.
@test "pr-auto-review-reusable: emits a decision no-op step per outcome branch + writes the output" {
  local wf="$SCRIPT_DIR/.github/workflows/pr-auto-review-reusable.yml" c
  for c in dispatched skip-draft skip-checks-pending skip-changes-requested skip-unresolved-threads; do
    run grep -F "name: 'decision: $c'" "$wf"
    [ "$status" -eq 0 ]
    run grep -F "decision=$c" "$wf"
    [ "$status" -eq 0 ]
  done
  # each decision step is a side-effect-free no-op
  run grep -c "run: 'true'" "$wf"
  [ "$output" -ge 5 ]
}

# ── #668 L2: engine — sample the decision mix + overlay the gate (with gh stubs) ─
# dev-lead layout (next=cand cccc, rings=prior bbbb, cut 3d ago, reusable identical → differs=0)
# PLUS a decision-mix sample: source-tier (next=.github-private) CANDIDATE runs (createdAt 1d ago,
# ids ≥2000, class=<cand_class>) and prior-version BASELINE runs (createdAt 7d ago, ids <2000,
# class=<base_class>). `run view` returns the taken decision no-op step for a run id. gate.correctness
# is injected onto the dev-lead clone in $CORR_RINGS so the opt-in overlay fires.
_correctness_stub() {
  local cand_class="$1" cand_n="$2" base_class="$3" base_n="$4"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local cut_iso cand_iso base_iso
  cut_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api
GITEOF
  chmod +x "$STUB_BIN/git"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "blobAAAA" ;;
  *"ref=bbbb"*) echo "blobAAAA" ;;
  *"run view"*)
    id="\$3"; cls="$base_class"
    [ "\$id" -ge 2000 ] 2>/dev/null && cls="$cand_class"
    jq -nc --arg cls "\$cls" '{jobs:[{steps:[
      {name:"Resolve PR URL",conclusion:"success"},
      {name:"decision: skip-unresolved-threads",conclusion:"skipped"},
      {name:("decision: "+\$cls),conclusion:"success"}
    ]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" \
      --argjson cn "$cand_n" --argjson bn "$base_n" '
      ( [range(2001;2001+\$cn)|{databaseId:.,conclusion:"success",createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(1001;1001+\$bn)|{databaseId:.,conclusion:"success",createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  CORR_RINGS="$BATS_TEST_TMPDIR/corr-rings.json"
  jq '.agents["dev-lead"].gate.correctness = {decision_step_prefix:"decision: ",min_candidate_sample:10,min_baseline_sample:20,max_shift_permille:400}' "$RINGS" > "$CORR_RINGS"
}

_CORR_CAND="cccccccccccccccccccccccccccccccccccccccc"
_corr_cut() { date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

@test "_correctness_verdict: a gross candidate decision-mix shift → SHIFT" {
  _correctness_stub skip-checks-pending 20 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash -c "source '$ORCH' && _correctness_verdict dev-lead $_CORR_CAND '$(_corr_cut)' petry-projects/.github-private"
  [ "$status" -eq 0 ]; [ "$output" = "SHIFT" ]
}
@test "_correctness_verdict: candidate mix matches the baseline → OK (no effect)" {
  _correctness_stub dispatched 20 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash -c "source '$ORCH' && _correctness_verdict dev-lead $_CORR_CAND '$(_corr_cut)' petry-projects/.github-private"
  [ "$status" -eq 0 ]; [ "$output" = "OK" ]
}
@test "_correctness_verdict: candidate sample below the minimum → INSUFFICIENT (no-op)" {
  _correctness_stub dispatched 5 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash -c "source '$ORCH' && _correctness_verdict dev-lead $_CORR_CAND '$(_corr_cut)' petry-projects/.github-private"
  [ "$status" -eq 0 ]; [ "$output" = "INSUFFICIENT" ]
}

@test "orchestrator: evaluate — a decision-mix SHIFT holds an otherwise-PROMOTE candidate as BLOCKED/SUSPECT (#668 L2)" {
  _correctness_stub skip-checks-pending 20 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" == *"decision-mix shift"* ]]
}
@test "orchestrator: evaluate — an in-threshold decision mix leaves the PROMOTE verdict untouched (#668 L2)" {
  _correctness_stub dispatched 20 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMOTE"* ]]
  ! [[ "$output" == *"decision-mix shift"* ]]
}
@test "orchestrator: evaluate — an agent WITHOUT gate.correctness never runs the overlay (byte-identical, #668 L2)" {
  # Same PROMOTE layout, default registry (dev-lead has no correctness block) → no sampling, no SUSPECT.
  _graduated_stub 3 2 success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMOTE"* ]]
  ! [[ "$output" == *"decision-mix"* ]]
  ! [[ "$output" == *"SUSPECT"* ]]
}

# sync-issues renders the candidate-vs-baseline decision-mix table into the blocker body for a
# correctness SHIFT (dev-lead-only registry keeps the fleet loop to one agent; gh logs issue ops).
_correctness_sync_stub() {
  local cand_class="$1" cand_n="$2" base_class="$3" base_n="$4" blocker_list="${5:-[]}"
  _correctness_stub "$cand_class" "$cand_n" "$base_class" "$base_n"
  export ISSUE_LOG="$STUB_BIN/issue.log"; : > "$ISSUE_LOG"
  # Extend the gh stub with issue ops (append the new cases BEFORE the catch-all).
  local cut_iso cand_iso base_iso
  cut_iso="$(_corr_cut)"
  cand_iso="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  base_iso="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "blobAAAA" ;;
  *"ref=bbbb"*) echo "blobAAAA" ;;
  *"run view"*)
    id="\$3"; cls="$base_class"
    [ "\$id" -ge 2000 ] 2>/dev/null && cls="$cand_class"
    jq -nc --arg cls "\$cls" '{jobs:[{steps:[
      {name:"Resolve PR URL",conclusion:"success"},
      {name:"decision: skip-unresolved-threads",conclusion:"skipped"},
      {name:("decision: "+\$cls),conclusion:"success"}
    ]}]}' ;;
  *"run list"*)
    since=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--created" ] && since="\$a"; prev="\$a"; done
    since="\${since#>=}"
    jq -nc --arg s "\$since" --arg cc "$cand_iso" --arg bb "$base_iso" \
      --argjson cn "$cand_n" --argjson bn "$base_n" '
      ( [range(2001;2001+\$cn)|{databaseId:.,conclusion:"success",createdAt:\$cc,workflowName:"Dev-Lead Agent"}]
      + [range(1001;1001+\$bn)|{databaseId:.,conclusion:"success",createdAt:\$bb,workflowName:"Dev-Lead Agent"}] )
      | map(select(\$s=="" or .createdAt >= \$s))' ;;
  "issue list"*)   echo '$blocker_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/petry-projects/.github-private/issues/777" ;;
  "issue edit"*)   echo "EDIT|\$*"   >> "$ISSUE_LOG" ;;
  "issue close"*)  echo "CLOSE|\$*"  >> "$ISSUE_LOG" ;;
  "issue reopen"*) echo "REOPEN|\$*" >> "$ISSUE_LOG" ;;
  "label create"*) : ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # dev-lead-only registry (with the correctness block) so the fleet loop stays a single agent.
  CORR_RINGS="$BATS_TEST_TMPDIR/corr-sync-rings.json"
  jq '{org_infra_repos, agents: {"dev-lead": (.agents["dev-lead"] | .gate.correctness = {decision_step_prefix:"decision: ",min_candidate_sample:10,min_baseline_sample:20,max_shift_permille:400})}}' "$RINGS" > "$CORR_RINGS"
}

@test "orchestrator: sync-issues renders the decision-mix table in the blocker for a correctness SHIFT (#668 L2)" {
  _correctness_sync_stub skip-checks-pending 20 dispatched 22 '[]'
  run env CANARY_RINGS="$CORR_RINGS" ISSUE_REPO="petry-projects/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  # The blocker body (passed to `gh issue create --body`) carries the correctness note + mix table.
  grep -q "decision-mix shift" "$ISSUE_LOG"
  grep -q "decision class" "$ISSUE_LOG"
  grep -q "candidate" "$ISSUE_LOG"
  grep -q "skip-checks-pending" "$ISSUE_LOG"
  # SUSPECT → routed to a human (needs-human) as well as the dev-lead agent.
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

# ══ major-scoped channels: v<major>-<tier> resolution + promotion (epic #657, F4) ══
# F4 makes the engine CAPABLE of operating on major-scoped `<agent>/v<M>-<tier>` channel tags
# while remaining fall-back-safe on today's bare-tier fleet: resolution prefers the v-form when
# that tag exists, else the legacy bare `<agent>/<tier>`. The transition-safety guard is that on
# the bare fixture the engine is byte-identical to pre-F4 (F5, not F4, migrates the live tags).

# ── pure name-builders (mirror F3 ring_canonical_ref convention) ────────────────
@test "channel_tag: with a major builds the v-scoped form (matches ring-pins convention)" {
  [ "$(channel_tag dev-lead next 2)" = "dev-lead/v2-next" ]
  [ "$(channel_tag auto-rebase stable 3)" = "auto-rebase/v3-stable" ]
}
@test "channel_tag: without a major builds the legacy bare form" {
  [ "$(channel_tag dev-lead next)" = "dev-lead/next" ]
  [ "$(channel_tag dev-lead stable '')" = "dev-lead/stable" ]
}
@test "major_component: extracts the MAJOR of a strict semver" {
  [ "$(major_component 2.3.1)" = "2" ]
  [ "$(major_component 10.0.0)" = "10" ]
}
@test "major_component: a non-semver token yields empty (no false major)" {
  [ -z "$(major_component 2-next)" ]
  [ -z "$(major_component '')" ]
  [ -z "$(major_component v2.0.0)" ]
}
@test "_looks_like_oid: accepts valid 7-char and 40-char lowercase hex" {
  _looks_like_oid "a1b2c3d"
  _looks_like_oid "abc1234def5678901234567890123456789012345678901234567890123456"
  _looks_like_oid "0000000000000000000000000000000000000000"
}
@test "_looks_like_oid: accepts 64-char hex (max length)" {
  _looks_like_oid "$(printf '%064x' 255)"
}
@test "_looks_like_oid: rejects uppercase hex, short ids, and non-hex tokens" {
  run _looks_like_oid "A1B2C3D"; [ "$status" -ne 0 ]
  run _looks_like_oid "abc123"; [ "$status" -ne 0 ]
  run _looks_like_oid ""; [ "$status" -ne 0 ]
  run _looks_like_oid "{}"; [ "$status" -ne 0 ]
  run _looks_like_oid "dev-lead/next"; [ "$status" -ne 0 ]
}

# ── _is_release_tag_suffix: only <agent>/v<M>.<m>.<p> counts as a release tag (#1046) ──
# The suffix is the tag name minus the "<agent>/" prefix, so an immutable release is
# "v139.4.0" while a v-scoped channel tag is "v139-next". Only the former is a release.
@test "_is_release_tag_suffix: accepts a strict vMAJOR.MINOR.PATCH suffix" {
  _is_release_tag_suffix "v139.4.0"
  _is_release_tag_suffix "v1.0.0"
  _is_release_tag_suffix "v10.20.30"
}
@test "_is_release_tag_suffix: rejects a v-scoped channel tag suffix (the #1046 shadow)" {
  run _is_release_tag_suffix "v139-next";  [ "$status" -eq 1 ]
  run _is_release_tag_suffix "v139-ring0"; [ "$status" -eq 1 ]
  run _is_release_tag_suffix "v2-stable";  [ "$status" -eq 1 ]
}
@test "_is_release_tag_suffix: rejects bare channel tags and other non-release refs" {
  run _is_release_tag_suffix "next";     [ "$status" -eq 1 ]
  run _is_release_tag_suffix "stable";   [ "$status" -eq 1 ]
  run _is_release_tag_suffix "v139";     [ "$status" -eq 1 ]   # not a full semver
  run _is_release_tag_suffix "v139.4";   [ "$status" -eq 1 ]   # missing patch
  run _is_release_tag_suffix "139.4.0";  [ "$status" -eq 1 ]   # missing the v prefix
  run _is_release_tag_suffix "";         [ "$status" -eq 1 ]
}

# ── _gh_candidate_cut_date / candidate_cut_date: a v-scoped channel tag must NOT shadow
#    the release tag (#1046). matching-refs and for-each-ref both sort "-" (0x2D) before
#    "." (0x2E), so <agent>/v139-next always precedes <agent>/v139.4.0 — the exact live
#    ordering that returned an empty cut date and wedged the gate at BLOCKED (indeterminate).
_X="33451103a2cfa8f64449df9030e6e7628381b406"   # candidate commit (both tags point here)
_CUT="2026-08-31T23:37:09Z"                       # the release tag's tagger date

@test "_gh_candidate_cut_date (cross-repo API): annotated release resolves even when a lightweight v-channel tag sorts earlier at the same commit (#1046)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"matching-refs/tags/dev-lead/v"*)
    printf 'refs/tags/dev-lead/v139-next\t%s\tcommit\n' "$_X"       # lightweight channel, sorts FIRST
    printf 'refs/tags/dev-lead/v139.4.0\ttagobj139\ttag\n' ;;        # annotated release
  *"git/tags/tagobj139"*) printf '%s\t%s\n' "$_X" "$_CUT" ;;
  *) echo "" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash -c "source '$ORCH' && _gh_candidate_cut_date petry-projects/.github-private dev-lead $_X"
  [ "$status" -eq 0 ]
  [ "$output" = "$_CUT" ]
}

@test "_gh_candidate_cut_date (cross-repo API): only a v-channel tag at the commit → empty (no release found)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"matching-refs/tags/dev-lead/v"*)
    printf 'refs/tags/dev-lead/v139-next\t%s\tcommit\n' "$_X" ;;    # channel tag ONLY, no release
  *) echo "" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash -c "source '$ORCH' && _gh_candidate_cut_date petry-projects/.github-private dev-lead $_X"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_gh_candidate_cut_date (cross-repo API): resolves release ref when many channel refs precede it (pagination guard)" {
  # Regression for the pagination gap: --paginate is required so that a release tag
  # which the API returns after a full page of channel refs is not silently dropped.
  # The stub returns ring0..ring3 channel refs before the release ref, simulating the
  # ordering that would push the release onto page 2 of a real paginated response.
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"matching-refs/tags/dev-lead/v"*)
    printf 'refs/tags/dev-lead/v139-ring0\t%s\tcommit\n' "$_X"
    printf 'refs/tags/dev-lead/v139-ring1\t%s\tcommit\n' "$_X"
    printf 'refs/tags/dev-lead/v139-ring2\t%s\tcommit\n' "$_X"
    printf 'refs/tags/dev-lead/v139-ring3\t%s\tcommit\n' "$_X"
    printf 'refs/tags/dev-lead/v139.4.0\ttagobj139\ttag\n' ;;   # release — sorts after all channel refs
  *"git/tags/tagobj139"*) printf '%s\t%s\n' "$_X" "$_CUT" ;;
  *) echo "" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  run bash -c "source '$ORCH' && _gh_candidate_cut_date petry-projects/.github-private dev-lead $_X"
  [ "$status" -eq 0 ]
  [ "$output" = "$_CUT" ]
}

@test "candidate_cut_date (cross-repo): dev-lead routes to the API path and resolves past a shadowing v-channel tag (#1046)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"matching-refs/tags/dev-lead/v"*)
    printf 'refs/tags/dev-lead/v139-next\t%s\tcommit\n' "$_X"
    printf 'refs/tags/dev-lead/v139.4.0\ttagobj139\ttag\n' ;;
  *"git/tags/tagobj139"*) printf '%s\t%s\n' "$_X" "$_CUT" ;;
  *) echo "" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # GITHUB_REPOSITORY=.github forces THIS_REPO=.github, so dev-lead (host .github-private) is cross-repo.
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && candidate_cut_date dev-lead $_X"
  [ "$status" -eq 0 ]
  [ "$output" = "$_CUT" ]
}

@test "candidate_cut_date (same-repo for-each-ref): annotated release resolves its TAGGER date past a lightweight v-channel tag at the same commit (#1046)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  # gh is only reached for _agent_current_major (matching-refs) — return no versions so the
  # bare-tier path is taken and does not interfere with the local cut-date resolution.
  printf '#!/usr/bin/env bash\necho ""\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  # git for-each-ref emits refname|objectname|*objectname|creatordate. The lightweight channel
  # tag (empty deref) sorts first; the annotated release (deref = candidate) carries the tagger date.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*)
    printf 'refs/tags/auto-rebase/v139-next|%s||\n' "$_X"
    printf 'refs/tags/auto-rebase/v139.4.0|tagobj139|%s|%s\n' "$_X" "$_CUT" ;;
  *"log -1"*) echo "COMMIT-DATE-FALLBACK" ;;   # must NOT be reached — a release tag resolves
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  # auto-rebase host = .github == THIS_REPO → the local for-each-ref path.
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && candidate_cut_date auto-rebase $_X"
  [ "$status" -eq 0 ]
  [ "$output" = "$_CUT" ]
  [[ "$output" != *"FALLBACK"* ]]
}


# ── _is_evicted_run: concurrency-eviction classifier (#1047, slice 1 of #1054) ──
# A run is an EVICTION (return 0) iff conclusion is exactly "cancelled" AND the
# completed-step count is exactly 0 — a concurrency `cancel-in-progress` preemption
# that executed no candidate code. Every other shape fails closed (return non-zero)
# so the gate keeps counting it: a cancel AFTER real work stays genuinely ambiguous.
@test "_is_evicted_run: cancelled + 0 completed steps IS an eviction" {
  _is_evicted_run cancelled 0
}
@test "_is_evicted_run: cancelled + a non-zero step count is NOT an eviction (human cancel mid-flight)" {
  run _is_evicted_run cancelled 3
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: success + 0 steps is NOT an eviction" {
  run _is_evicted_run success 0
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: failure + 0 steps is NOT an eviction" {
  run _is_evicted_run failure 0
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: an empty step count is NOT an eviction (fail closed)" {
  run _is_evicted_run cancelled ""
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: a non-numeric step count is NOT an eviction (fail closed)" {
  run _is_evicted_run cancelled abc
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: a missing step-count argument is NOT an eviction (fail closed)" {
  run _is_evicted_run cancelled
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: no arguments at all is NOT an eviction (fail closed)" {
  run _is_evicted_run
  [ "$status" -ne 0 ]
}
@test "_is_evicted_run: emits nothing on either branch" {
  run _is_evicted_run cancelled 0
  [ -z "$output" ]
  run _is_evicted_run cancelled 3
  [ -z "$output" ]
}
# ── a fleet whose v2 major line EXISTS: v2-next=cand(cccc), v2-ring0/ring1/stable=old(bbbb) →
#    frontier ring0, transition next->ring0. Bare tags resolve to a DIFFERENT sha (aaaa) so a test
#    can prove the engine PREFERS the v-form. Ref mutations are logged to MOVE_LOG.
_vline_stub() {
  local cut_days="$1" run_days_ago="$2" conclusion="$3"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export MOVE_LOG="$STUB_BIN/move.log"
  local cand="cccccccccccccccccccccccccccccccccccccccc"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local bare="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"-X POST"*"git/refs"*)        echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"git/ref/tags/dev-lead/v2-next"*)   echo "$cand commit" ;;
  *"git/ref/tags/dev-lead/v2-ring0"*)  echo "$old commit" ;;
  *"git/ref/tags/dev-lead/v2-ring1"*)  echo "$old commit" ;;
  *"git/ref/tags/dev-lead/v2-stable"*) echo "$old commit" ;;
  *"git/ref/tags/dev-lead/next"*)   echo "$bare commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "$bare commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "$bare commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "$bare commit" ;;
  # _gh_candidate_cut_date reads the 3-col @tsv shape; _host_release_versions reads plain .ref.
  # The established v2 line means its v2-next anchor is a tag under <agent>/v, so it appears in
  # the .ref listing too — that is how _agent_current_channel_major reads the channel major (#1065).
  *"matching-refs/tags/dev-lead/v"*"@tsv"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\nrefs/tags/dev-lead/v2-next\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "$cand" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseAAAA" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api above
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: resolution prefers the v2 line + evaluate reports the major line (#657 F4)" {
  _vline_stub 3 2 success
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  # The candidate + ring listing report the major line, not the bare tier.
  [[ "$output" == *"candidate (v2-next)"* ]]
  [[ "$output" == *"v2-stable"* ]]
  [[ "$output" != *"candidate (next) ="* ]]
  # The v-form is PREFERRED: the candidate resolves to cccc (v2-next), never the bare aaaa.
  [[ "$output" == *"cccccccccccc"* ]]
  [[ "$output" != *"aaaaaaaaaaaa"* ]]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"PROMOTE"* ]]
}

@test "orchestrator: promote advances WITHIN a major line — moves v2-ring0, never a v1 tag (#657 F4)" {
  _vline_stub 3 2 success
  local out="$BATS_TEST_TMPDIR/gh_output"; : > "$out"
  run env CANARY_RINGS="$RINGS" GITHUB_OUTPUT="$out" bash "$ORCH" promote dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted dev-lead/v2-ring0"* ]]
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/v2-ring0" "$MOVE_LOG"
  # A v2 promotion NEVER touches a v1-* tag.
  ! grep -q "v1-" "$MOVE_LOG"
  # promoted_ring stays the logical tier (ring0), not the major-scoped tag.
  grep -q "promoted_ring=ring0" "$out"
}

@test "orchestrator: on the bare-tier fixture the verdict is byte-identical to pre-F4 (transition-safety) (#657 F4)" {
  # No v-tags exist (the v-form probe resolves absent) → resolution falls back to the bare tier,
  # so the candidate + verdict are exactly what pre-F4 produced on this fixture.
  _graduated_stub 3 2 success 0
  run env CANARY_RINGS="$RINGS" bash "$ORCH" evaluate dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate (next) ="* ]]
  [[ "$output" != *"candidate (v"* ]]
  [[ "$output" == *"next->ring0"* ]]
  [[ "$output" == *"PROMOTE"* ]]
}

# ══ AC1′ / AC3 / AC4′ (#1065): the v-scoped line must BOOTSTRAP into a new tier ═══════
# Once an agent has an ESTABLISHED channel major (its `<agent>/v<M>-next` anchor exists), a
# promotion into a tier whose `<agent>/v<M>-<tier>` does not yet exist must CREATE that tag —
# not fall back to the bare tier. The old fallback stranded the v-line at whatever tier it was
# first seeded at (apply-repo-settings needed a hand-cut v1-ring1; persona-mention is stuck at
# ring0/ring1), and a stub deploy keyed on the channel major then pinned a nonexistent ref.
#
# Fixture: dev-lead (cross-repo). `established=1` seeds v1-next at the candidate (cccc) but
# leaves v1-ring0/ring1/stable ABSENT; the bare tiers point elsewhere (bbbb) so a test can prove
# resolution NEVER falls back to them. `established=0` leaves v1-next absent (a v1 release exists,
# but no v-line was ever seeded — the legacy bare-only case), so the bare next carries the
# candidate. Every ref write is captured in MOVE_LOG; a nonexistent v-tag PATCH returns 422 so the
# create-if-missing POST path is exercised (the real bootstrap).
_ac1_stub() {
  local established="$1" cut_days="${2:-3}" run_days_ago="${3:-2}" conclusion="${4:-success}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export MOVE_LOG="$STUB_BIN/move.log"; : > "$MOVE_LOG"
  local cand="cccccccccccccccccccccccccccccccccccccccc"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local v1next="$cand" barenext="$old"
  if [ "$established" = 0 ]; then v1next=""; barenext="$cand"; fi   # no v-line → bare next IS the candidate
  local cut_iso run_iso
  cut_iso="$(date -u -d "-${cut_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${cut_days}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  run_iso="$(date -u -d "-${run_days_ago} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"-${run_days_ago}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"-X PATCH"*"git/refs/tags/dev-lead/v1-ring"*|*"-X PATCH"*"git/refs/tags/dev-lead/v1-stable"*)
    echo "\$*" >> "$MOVE_LOG"; echo "gh: Reference does not exist (HTTP 422)" >&2; exit 1 ;;
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"-X POST"*"git/refs"*)        echo "\$*" >> "$MOVE_LOG"; echo "{}"; exit 0 ;;
  *"git/ref/tags/dev-lead/v1-next"*)   [ -n "$v1next" ] && echo "$v1next commit" || printf '\n' ;;
  *"git/ref/tags/dev-lead/v1-ring0"*)  printf '\n' ;;
  *"git/ref/tags/dev-lead/v1-ring1"*)  printf '\n' ;;
  *"git/ref/tags/dev-lead/v1-stable"*) printf '\n' ;;
  *"git/ref/tags/dev-lead/next"*)   echo "$barenext commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "$old commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "$old commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "$old commit" ;;
  # _gh_candidate_cut_date reads the 3-col @tsv shape; _host_release_versions reads plain .ref.
  # When the v1 line is established its v1-next anchor is a tag under <agent>/v, so it surfaces in
  # the .ref listing — how _agent_current_channel_major derives the channel major (#1065).
  *"matching-refs/tags/dev-lead/v"*"@tsv"*) printf 'refs/tags/dev-lead/v1.0.0\ttagobj\ttag\n' ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v1.0.0\n'; [ -n "$v1next" ] && printf 'refs/tags/dev-lead/v1-next\n' || true ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "$cand" "$cut_iso" ;;
  *"ref=cccc"*) echo "reuseAAAA" ;;
  *"ref=bbbb"*) echo "reuseAAAA" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$conclusion" '[range(20)|{conclusion:\$c,createdAt:\$d}]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag/blob resolution goes via gh api above
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "orchestrator: promote BOOTSTRAPS the v-scoped tier tag — creates dev-lead/v1-ring0, never moves the bare ring0 (#1065 AC1′/AC4′)" {
  _ac1_stub 1
  local out="$BATS_TEST_TMPDIR/gh_output"; : > "$out"
  run env CANARY_RINGS="$RINGS" GITHUB_OUTPUT="$out" bash "$ORCH" promote dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted dev-lead/v1-ring0"* ]]
  # the v-scoped tier tag is CREATED (PATCH 422 → POST create) at the candidate
  grep -q "ref=refs/tags/dev-lead/v1-ring0" "$MOVE_LOG"
  # resolution NEVER falls back to the bare tier: no write targets the bare ring0
  run grep -q "git/refs/tags/dev-lead/ring0" "$MOVE_LOG"
  [ "$status" -eq 1 ]
  run grep -q "ref=refs/tags/dev-lead/ring0" "$MOVE_LOG"
  [ "$status" -eq 1 ]
  # a promotion moves exactly one frontier tag — it never touches the next anchor
  run grep -q "v1-next" "$MOVE_LOG"
  [ "$status" -eq 1 ]
  # promoted_ring stays the logical tier, not the major-scoped tag name
  grep -q "promoted_ring=ring0" "$out"
}

@test "orchestrator: promote of an agent with NO channel major still moves the bare tier tag and creates no v-scoped tag (#1065 AC4′ inverse)" {
  _ac1_stub 0
  local out="$BATS_TEST_TMPDIR/gh_output"; : > "$out"
  run env CANARY_RINGS="$RINGS" GITHUB_OUTPUT="$out" bash "$ORCH" promote dev-lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted dev-lead/ring0"* ]]
  [[ "$output" != *"v1-ring0"* ]]
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/ring0 " "$MOVE_LOG"
  # a release major alone (no v-line seeded) must NOT sprout a v-scoped tag
  run grep -q "v1-" "$MOVE_LOG"
  [ "$status" -eq 1 ]
  grep -q "promoted_ring=ring0" "$out"
}

# ── AC3: the drift audit flags a bare tier tag lacking its v<M>-<tier> counterpart ──
@test "_channel_tag_major_gaps: flags every tier whose bare tag exists but v<M>-<tier> is missing (#1065 AC3)" {
  _ac1_stub 1
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' _channel_tag_major_gaps dev-lead"
  [ "$status" -eq 0 ]
  # v1-next is present (no gap); ring0/ring1/stable have a bare tag but no v-scoped counterpart.
  [[ "$output" == *"ring0"* ]]
  [[ "$output" == *"ring1"* ]]
  [[ "$output" == *"stable"* ]]
  [[ "$output" != *"next"* ]]
}

@test "_channel_tag_major_gaps: an agent with NO channel major reports no gaps (legacy bare-only) (#1065 AC3)" {
  _ac1_stub 0
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' _channel_tag_major_gaps dev-lead"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A single-agent registry mirroring the issue: persona-mention has an established v1 channel
# major (v1-next) but only bare ring0/ring1 — v1-ring0/v1-ring1 are missing.
_channeldrift_stub() {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local main="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local old="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"contents/.github/workflows"*) echo '[{"type":"file","name":"persona-mention-reusable.yml","path":".github/workflows/persona-mention-reusable.yml"}]' ;;
  *".default_branch"*) echo "main" ;;
  *"/commits/"*) echo "$main" ;;
  *"git/ref/tags/persona-mention/v1-next"*)   printf '%s\tcommit\n' "$main" ;;
  *"git/ref/tags/persona-mention/v1-ring0"*)  printf '\n' ;;
  *"git/ref/tags/persona-mention/v1-ring1"*)  printf '\n' ;;
  *"git/ref/tags/persona-mention/v1-stable"*) printf '\n' ;;
  *"git/ref/tags/persona-mention/next"*)   printf '%s\tcommit\n' "$main" ;;
  *"git/ref/tags/persona-mention/ring0"*)  printf '%s\tcommit\n' "$old" ;;
  *"git/ref/tags/persona-mention/ring1"*)  printf '%s\tcommit\n' "$old" ;;
  *"git/ref/tags/persona-mention/stable"*) printf '\n' ;;
  *"matching-refs/tags/persona-mention/v"*) printf 'refs/tags/persona-mention/v1.0.0\nrefs/tags/persona-mention/v1-next\n' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # cross-repo agent resolves channel tags via gh api, not git
GITEOF
  chmod +x "$STUB_BIN/git"
  CHANNELDRIFT_RINGS="$BATS_TEST_TMPDIR/channeldrift-rings.json"
  jq '{version, description, agents: {("persona-mention"): .agents["persona-mention"]}}' \
    "$RINGS" > "$CHANNELDRIFT_RINGS"
}

@test "orchestrator: drift reports a bare channel tag lacking its v<M>-<tier> counterpart (#1065 AC3)" {
  _channeldrift_stub
  # Force THIS_REPO=.github-private so persona-mention (host=.github) is cross-repo and resolves
  # its channel tags via gh api (the stub), not local git.
  run env GITHUB_REPOSITORY="petry-projects/.github-private" CANARY_RINGS="$CHANNELDRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[channel-tag]"* ]]
  [[ "$output" == *"persona-mention"* ]]
  [[ "$output" == *"v1-ring0"* ]]
  [[ "$output" == *"v1-ring1"* ]]
  # next has its v-scoped anchor and stable has no bare tag → neither is flagged.
  [[ "$output" == *"channel-tag drift summary: 2"* ]]
}

# ── autocut on the major dimension: a MAJOR bump seeds a fresh v<newmajor>-next line; a minor/
#    patch bump advances the CURRENT major's v<M>-next (falling back to bare next on today's fleet).
#    args: agent host reusable main_blob next_blob mainsha nextsha versions bump [v2next_sha]
_f4_autocut_stub() {
  local agent="$1" host="$2" reusable="$3" MAIN_BLOB="$4" NEXT_BLOB="$5" MAINSHA="$6" NEXTSHA="$7" versions="$8" bump="$9" V2NEXT="${10:-}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$STUB_BIN/gh-writes.log"; : > "$GH_LOG"
  local refs="" v
  for v in $versions; do refs+="refs/tags/$agent/v$v"$'\n'; done
  local v2next_resp=""
  # When the v2 channel line exists its `v2-next` anchor is a tag under `<agent>/v`, so it
  # surfaces in matching-refs alongside the releases (that is how _agent_current_channel_major
  # reads the channel major, #1065). Model that here too, not just the individual ref endpoint.
  [ -n "$V2NEXT" ] && { v2next_resp="${V2NEXT}"$'\t'"commit"; refs+="refs/tags/$agent/v2-next"$'\n'; }
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *".default_branch"*) echo "main" ;;
  *"contents/"*"ref=$MAINSHA"*) echo "$MAIN_BLOB" ;;
  *"contents/"*"ref=$NEXTSHA"*) echo "$NEXT_BLOB" ;;
  *"-X POST"*"git/tags"*) echo "\$*" >> "$GH_LOG"; echo "7a90000000000000000000000000000000000000" ;;
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$GH_LOG"; exit 0 ;;
  *"-X POST"*"git/refs"*) echo "\$*" >> "$GH_LOG"; echo "{}" ;;
  *"/commits/"*) echo "$MAINSHA" ;;
  *"matching-refs/tags/$agent/v"*) printf '%s' "$refs" ;;
  *"git/ref/tags/$agent/v2-next"*) printf '%s\n' "$v2next_resp" ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  *"git/ref/tags/$agent/v"*) printf '\n' ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"$agent/next"*) echo "$NEXTSHA" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  AUTOCUT_RINGS="$BATS_TEST_TMPDIR/f4-autocut-rings.json"
  jq --arg a "$agent" --arg b "$bump" \
    '{version, description, org_infra_repos, member_tokens, agents: {($a): (.agents[$a] + {autocut: {bump: $b}})}}' \
    "$RINGS" > "$AUTOCUT_RINGS"
}

@test "orchestrator: autocut of a MAJOR bump seeds a fresh v<newmajor>-next line, not the old next (#657 F4)" {
  _f4_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" major
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # major bump v2.1.0 → v3.0.0; the immutable release cut as usual, next seeded on the FRESH v3 line.
  grep -q "git/tags .*tag=dev-lead/v3.0.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/v3-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  # The fresh major line does NOT move the old bare next (that would break the running fleet).
  ! grep -q "git/refs/tags/dev-lead/next " "$GH_LOG"
}

@test "orchestrator: autocut of a patch bump advances the current major's v2-next when that line exists (#657 F4)" {
  _f4_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" patch \
    cccccccccccccccccccccccccccccccccccccccc
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # patch bump v2.1.0 → v2.1.1; the v2 line exists → next advances ON the major line, not bare next.
  grep -q "git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/v2-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "git/refs/tags/dev-lead/next " "$GH_LOG"
}

@test "orchestrator: autocut of a patch bump falls back to bare next when no v-line exists yet (#657 F4)" {
  # Today's bare fleet: no v2-next tag → resolution falls back to bare next → byte-identical move.
  _f4_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" patch
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "git/refs/tags/dev-lead/v2-next" "$GH_LOG"
}

# ── autocut breaking-change detection (#712, epic #1083 pillar 2) ──────────────
# When autocut cuts a candidate it now CLASSIFIES the change: a conventional-commit
# `!`/`BREAKING CHANGE` on a commit touching the reusable, or a workflow_call interface
# break (removed/renamed/newly-required input, removed secret) auto-produces a MAJOR
# (seeding a fresh v<newmajor>-next per F4); a non-breaking `feat` → minor, `fix` → patch;
# any signal-fetch error fails safe to patch. The `.agents[a].autocut.bump` knob overrides.
#
# The stub feeds, in addition to the plumbing the other autocut stubs mock: the commit list
# for `commits?path=<reusable>&sha=<mainsha>` (a JSON array, newest-first, terminated by a
# boundary commit with sha=<nextsha> that must be EXCLUDED) and the reusable's file CONTENT
# (base64, keyed by ref) so the interface diff can parse on.workflow_call at both refs.
#   args: agent host reusable mainsha nextsha versions commits_json old_yaml new_yaml [bump]
_detect_autocut_stub() {
  local agent="$1" host="$2" reusable="$3" MAINSHA="$4" NEXTSHA="$5" versions="$6"
  local commits_json="$7" old_yaml="$8" new_yaml="$9" bump="${10:-}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$STUB_BIN/gh-writes.log"; : > "$GH_LOG"
  local refs="" v
  for v in $versions; do refs+="refs/tags/$agent/v$v"$'\n'; done
  printf '%s' "$commits_json" > "$STUB_BIN/commits.json"
  local NEW_B64 OLD_B64
  NEW_B64="$(printf '%s' "$new_yaml" | base64 | tr -d '\n')"
  OLD_B64="$(printf '%s' "$old_yaml" | base64 | tr -d '\n')"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *".default_branch"*) echo "main" ;;
  *"/commits"*"-f path="*) cat "$STUB_BIN/commits.json" ;;
  *"/commits/"*) echo "$MAINSHA" ;;
  *"contents/"*"ref=$MAINSHA"*".content"*) echo "$NEW_B64" ;;
  *"contents/"*"ref=$NEXTSHA"*".content"*) echo "$OLD_B64" ;;
  *"contents/"*"ref=$MAINSHA"*) echo "blobNEW" ;;
  *"contents/"*"ref=$NEXTSHA"*) echo "blobOLD" ;;
  *"-X POST"*"git/tags"*) echo "\$*" >> "$GH_LOG"; echo "7a90000000000000000000000000000000000000" ;;
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$GH_LOG"; exit 0 ;;
  *"-X POST"*"git/refs"*) echo "\$*" >> "$GH_LOG"; echo "{}" ;;
  *"matching-refs/tags/$agent/v"*) printf '%s' "$refs" ;;
  *"git/ref/tags/$agent/v"*"-next"*) printf '\n' ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  *"git/ref/tags/$agent/v"*) printf '\n' ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"$agent/next"*) echo "$NEXTSHA" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  AUTOCUT_RINGS="$BATS_TEST_TMPDIR/detect-autocut-rings.json"
  if [ -n "$bump" ]; then
    jq --arg a "$agent" --arg b "$bump" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): (.agents[$a] + {autocut: {bump: $b}})}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  else
    jq --arg a "$agent" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): .agents[$a]}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  fi
}

# A workflow_call interface with one required + one optional input and a secret.
_iface_yaml() {
  cat <<'YML'
name: dev-lead-reusable
on:
  workflow_call:
    inputs:
      target:
        required: true
        type: string
      dry_run:
        required: false
        type: boolean
    secrets:
      APP_TOKEN:
        required: true
jobs:
  run:
    runs-on: ubuntu-latest
    steps: []
YML
}

@test "orchestrator: autocut detects a feat! commit → MAJOR + seeds a fresh v<newmajor>-next (#712)" {
  local commits='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"feat!: drop the legacy dry_run input\n\nRemoves a caller-facing knob."}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  # interface unchanged (same yaml both refs) — the major comes purely from the commit signal.
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$(_iface_yaml)"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # major bump v2.1.0 → v3.0.0; next seeded on the FRESH v3 line, old bare next untouched.
  grep -q "git/tags .*tag=dev-lead/v3.0.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/v3-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "git/refs/tags/dev-lead/next " "$GH_LOG"
}

@test "orchestrator: autocut detects a removed workflow_call input → MAJOR (interface break) (#712)" {
  # Commits are non-breaking (fix) — the major comes from the interface diff: new yaml drops 'dry_run'.
  local commits='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"fix: internal cleanup"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  local new_yaml
  new_yaml="$(cat <<'YML'
name: dev-lead-reusable
on:
  workflow_call:
    inputs:
      target:
        required: true
        type: string
    secrets:
      APP_TOKEN:
        required: true
jobs:
  run:
    runs-on: ubuntu-latest
    steps: []
YML
)"
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$new_yaml"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v3.0.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/v3-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut detects a newly-required workflow_call input → MAJOR (interface break) (#712)" {
  local commits='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"fix: tidy"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  # new yaml adds a brand-new REQUIRED input 'workspace' — callers not passing it break.
  local new_yaml
  new_yaml="$(cat <<'YML'
name: dev-lead-reusable
on:
  workflow_call:
    inputs:
      target:
        required: true
        type: string
      dry_run:
        required: false
        type: boolean
      workspace:
        required: true
        type: string
    secrets:
      APP_TOKEN:
        required: true
jobs:
  run:
    runs-on: ubuntu-latest
    steps: []
YML
)"
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$new_yaml"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v3.0.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut detects a non-breaking feat commit → MINOR (#712)" {
  # feat adds an OPTIONAL input — non-breaking → minor.
  local commits='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"feat: add an optional verbose input"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  local new_yaml
  new_yaml="$(cat <<'YML'
name: dev-lead-reusable
on:
  workflow_call:
    inputs:
      target:
        required: true
        type: string
      dry_run:
        required: false
        type: boolean
      verbose:
        required: false
        type: boolean
    secrets:
      APP_TOKEN:
        required: true
jobs:
  run:
    runs-on: ubuntu-latest
    steps: []
YML
)"
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$new_yaml"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # minor bump v2.1.0 → v2.2.0
  grep -q "git/tags .*tag=dev-lead/v2.2.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "tag=dev-lead/v3" "$GH_LOG"
}

@test "orchestrator: autocut detects a fix-only change → PATCH (#712)" {
  local commits='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"fix: correct a log message"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$(_iface_yaml)"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut fails SAFE to PATCH when the commit-signal fetch errors (#712)" {
  # commits?path returns a non-array error payload → signal fetch fails → never auto-major.
  local commits='{"message":"Not Found","status":"404"}'
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$(_iface_yaml)"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "tag=dev-lead/v3" "$GH_LOG"
}

@test "orchestrator: autocut knob override forces MAJOR over a patch-only diff (#712)" {
  # Signals say patch (fix commit, no interface change) but the registry knob forces major.
  local commits='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"fix: small tweak"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  _detect_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "$commits" "$(_iface_yaml)" "$(_iface_yaml)" major
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v3.0.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github-private/git/refs/tags/dev-lead/v3-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

# ── autocut bump-signal scoping + pagination + fail-safe (#1023 defect 1) ───────
# Signals are derived ONLY from commits touching a WATCHED path (reusable + optional
# .agents[a].autocut.watched_paths[]), and the range is ENUMERATED with pagination + a `since`
# window instead of trusting one capped response. An unrelated feat!/BREAKING outside the watched
# paths must NOT raise the bump; a BREAKING beyond the first page's cap MUST still be detected;
# and a range that cannot be enumerated fails safe to MAJOR (loudly), never silently to patch.
#
# The stub serves the reusable path's commit list PER PAGE (re-<n>.json) and, for any OTHER
# watched path, an "extra" list (ex-1.json) — so scoping and multi-path union can be exercised
# distinctly. The boundary commit (sha=NEXTSHA) terminates a list and is EXCLUDED from signals.
#   args: agent host reusable MAINSHA NEXTSHA versions date re_page1 [re_page2] [ex_page1] [watched_paths_json]
_scoped_autocut_stub() {
  local agent="$1" host="$2" reusable="$3" MAINSHA="$4" NEXTSHA="$5" versions="$6" date="$7"
  local re1="${8:-[]}" re2="${9:-[]}" ex1="${10:-[]}" watched="${11:-}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$STUB_BIN/gh-writes.log"; : > "$GH_LOG"
  local refs="" v; for v in $versions; do refs+="refs/tags/$agent/v$v"$'\n'; done
  printf '%s' "$re1" > "$STUB_BIN/re-1.json"
  printf '%s' "$re2" > "$STUB_BIN/re-2.json"
  printf '%s' "$ex1" > "$STUB_BIN/ex-1.json"
  local IFACE; IFACE="$(_iface_yaml)"
  local B64; B64="$(printf '%s' "$IFACE" | base64 | tr -d '\n')"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
args="\$*"
page="\$(printf '%s' "\$args" | sed -n 's/.*page=\\([0-9]*\\).*/\\1/p')"; page="\${page:-1}"
case "\$args" in
  *".default_branch"*) echo "main" ;;
  *"/commits"*"-f path=$reusable"*)
    f="$STUB_BIN/re-\$page.json"; [ -f "\$f" ] && cat "\$f" || echo "[]" ;;
  *"/commits"*"-f path="*)
    f="$STUB_BIN/ex-\$page.json"; [ -f "\$f" ] && cat "\$f" || echo "[]" ;;
  *"/commits/$NEXTSHA"*) echo "$date" ;;
  *"/commits/"*) echo "$MAINSHA" ;;
  *"contents/"*"ref=$MAINSHA"*".content"*) echo "$B64" ;;
  *"contents/"*"ref=$NEXTSHA"*".content"*) echo "$B64" ;;
  *"contents/"*"ref=$MAINSHA"*) echo "blobNEW" ;;
  *"contents/"*"ref=$NEXTSHA"*) echo "blobOLD" ;;
  *"-X POST"*"git/tags"*) echo "\$args" >> "$GH_LOG"; echo "7a90000000000000000000000000000000000000" ;;
  *"-X PATCH"*"git/refs/tags/"*) echo "\$args" >> "$GH_LOG"; exit 0 ;;
  *"-X POST"*"git/refs"*) echo "\$args" >> "$GH_LOG"; echo "{}" ;;
  *"matching-refs/tags/$agent/v"*) printf '%s' "$refs" ;;
  *"git/ref/tags/$agent/v"*"-next"*) printf '\n' ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  *"git/ref/tags/$agent/v"*) printf '\n' ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in *"rev-parse"*"$agent/next"*) echo "$NEXTSHA" ;; *) : ;; esac
GITEOF
  chmod +x "$STUB_BIN/git"
  AUTOCUT_RINGS="$BATS_TEST_TMPDIR/scoped-autocut-rings.json"
  if [ -n "$watched" ]; then
    jq --arg a "$agent" --argjson w "$watched" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): (.agents[$a] + {autocut: {watched_paths: $w}})}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  else
    jq --arg a "$agent" \
      '{version, description, org_infra_repos, member_tokens, agents: {($a): .agents[$a]}}' \
      "$RINGS" > "$AUTOCUT_RINGS"
  fi
}

# 100 non-breaking filler commits (a full page) so a signal beyond the cap sits on page 2.
_filler_page() { jq -nc '[range(100)|{sha:("f\(.)"),commit:{message:"chore: filler \(.)"}}]'; }

@test "orchestrator: autocut — an unrelated feat! OUTSIDE the watched paths does NOT raise the bump (#1023)" {
  # The reusable's path-scoped commit list carries only a fix; the boundary terminates it. The
  # `feat!` that would force a major touched an unrelated file (docs/), so it never appears in
  # `commits?path=<reusable>` and must not move the bump. Scoping ⇒ patch, not major.
  local re1='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"fix: correct a log line"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  _scoped_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "2026-08-01T00:00:00Z" "$re1"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v2.1.1 " "$GH_LOG"       # patch bump
  ! grep -q "tag=dev-lead/v3" "$GH_LOG"                     # NOT a spurious major
}

@test "orchestrator: autocut — a breaking feat! on a CONFIGURED extra watched path IS detected → major (#1023)" {
  # watched_paths adds a shared library; the reusable itself only had a fix, but the extra watched
  # path carries a `feat!`. Multi-path union ⇒ major (a change to a watched dependency counts).
  local re1='[{"sha":"newcommit0000000000000000000000000000","commit":{"message":"fix: reusable tidy"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  local ex1='[{"sha":"libcommit00000000000000000000000000000","commit":{"message":"feat!: drop the legacy shared entrypoint"}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  _scoped_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "2026-08-01T00:00:00Z" "$re1" "[]" "$ex1" '["scripts/lib/shared.sh"]'
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v3.0.0 " "$GH_LOG"
}

@test "orchestrator: autocut — a BREAKING CHANGE in a watched-path commit BEYOND the page cap IS detected → major (#1023)" {
  # Page 1 is a full 100-commit page of fillers (no boundary, no breaking); the boundary and the
  # BREAKING CHANGE commit are on page 2. If pagination stopped at the cap the break would ship as
  # a patch — the dangerous direction. Enumerating past the cap ⇒ major.
  local re2='[{"sha":"breaker000000000000000000000000000000000","commit":{"message":"feat: extend the matrix\n\nBREAKING CHANGE: the matrix input is now required."}},{"sha":"cccccccccccccccccccccccccccccccccccccccc","commit":{"message":"chore: prior baseline"}}]'
  _scoped_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "2026-08-01T00:00:00Z" "$(_filler_page)" "$re2"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v3.0.0 " "$GH_LOG"
}

@test "orchestrator: autocut — an UNRESOLVABLE range fails safe to MAJOR (loudly), never silently to patch (#1023)" {
  # Every page is a full 100-commit page and the boundary is never reached within the page cap →
  # the range cannot be enumerated. It must NOT silently downgrade to patch: fail safe to major
  # with a ::warning::.
  _scoped_autocut_stub dev-lead petry-projects/.github-private .github/workflows/dev-lead-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" \
    "2026-08-01T00:00:00Z" "$(_filler_page)" "$(_filler_page)"
  run env CANARY_AUTO_CUT=true CANARY_MAX_COMMIT_PAGES=2 CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v3.0.0 " "$GH_LOG"       # fail-safe MAJOR, not patch
  ! grep -q "tag=dev-lead/v2.1.1" "$GH_LOG"
  [[ "$output" == *"could not be fully enumerated"* ]]      # and it is LOUD
  [[ "$output" == *"failing safe to bump=major"* ]]
}

# ── workflow timeout headroom (#939) ─────────────────────────────────────────
# Fleet Monitor flagged canary-rollout.yml as DEGRADED (50% failure): the
# scheduled fleet sweep's p50 was 877s and p95 988s against a 15-min (900s)
# job timeout, so the tail of every sweep was being killed at the ceiling. The
# owner-wide run-history reads grow with the fleet, so the bound must sit well
# above the observed p95 (~16.5 min). This guard fails loud if the canary job's
# timeout-minutes is dropped back below that headroom floor.
WORKFLOW="$SCRIPT_DIR/.github/workflows/canary-rollout.yml"

@test "canary-rollout.yml: canary job declares a timeout-minutes" {
  local minutes
  minutes="$(awk '
    /^  canary:[[:space:]]*$/ { in_canary=1; next }
    in_canary && /^  [^[:space:]]/ { in_canary=0 }
    in_canary && /^[[:space:]]*timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/ {
      match($0, /[0-9]+/)
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$WORKFLOW")"
  [ -n "$minutes" ]
}

@test "canary-rollout.yml: canary job timeout-minutes keeps headroom over the observed p95 (#939)" {
  # Observed p95 was 988s (~16.5 min); require >= 20 min so the fleet sweep's
  # tail is not killed at the ceiling (the old 15-min bound must not return).
  local minutes
  minutes="$(awk '
    /^  canary:[[:space:]]*$/ { in_canary=1; next }
    in_canary && /^  [^[:space:]]/ { in_canary=0 }
    in_canary && /^[[:space:]]*timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/ {
      match($0, /[0-9]+/)
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$WORKFLOW")"
  [ -n "$minutes" ]
  [ "$minutes" -ge 20 ]
}

@test "canary-rollout.yml: canary job timeout-minutes covers the observed sweep time (#1259)" {
  # Since the ingress collapse (#1238) a scheduled sweep takes 20-42 min depending on GitHub API latency
  # (the longest observed so far: 42.5 min); at the old 30 min the last 7 consecutive sweeps were killed,
  # sync-issues never ran, and GitHub kept no logs for the cancelled jobs. Require >= 45 so the old 30-min
  # value cannot return silently. Lowering this later (once the gate steps are back near ~10 min each)
  # is a deliberate change to this floor, with the new measurements in the commit message.
  local minutes
  minutes="$(awk '
    /^  canary:[[:space:]]*$/ { in_canary=1; next }
    in_canary && /^  [^[:space:]]/ { in_canary=0 }
    in_canary && /^[[:space:]]*timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/ {
      match($0, /[0-9]+/)
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$WORKFLOW")"
  [ -n "$minutes" ]
  [ "$minutes" -ge 45 ]
}

# ── #1019: watched agent_ref paths (autocut covers scripts/prompts/personas) ────
# Autocut previously compared ONLY the reusable FILE blob, so a script-only change (what the
# reusable checks out at agent_ref) shipped nowhere. These pin the pure path-matcher core and
# the end-to-end autocut/drift/move/enum behaviour the fix adds.

# ── watched_hits / any_watched_change (pure path matcher) ──
@test "watched_hits: a changed file under a dir pattern is a hit (#1019)" {
  run watched_hits $'scripts/lib/foo.sh\ndocs/readme.md' $'scripts/\nprompts/'
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/" ]
}

@test "watched_hits: an exact file pattern matches (reusable) (#1019)" {
  run watched_hits $'.github/workflows/dev-lead-reusable.yml' $'.github/workflows/dev-lead-reusable.yml\nscripts/'
  [ "$output" = ".github/workflows/dev-lead-reusable.yml" ]
}

@test "watched_hits: no changed file under any watched pattern → empty (#1019)" {
  run watched_hits $'docs/readme.md\nREADME.md' $'scripts/\nprompts/\npersonas/'
  [ -z "$output" ]
}

@test "any_watched_change: 1 when a watched path changed, 0 otherwise (#1019)" {
  [ "$(any_watched_change $'scripts/x.sh' $'scripts/')" = "1" ]
  [ "$(any_watched_change $'docs/x.md' $'scripts/')" = "0" ]
  [ "$(any_watched_change '' $'scripts/')" = "0" ]
  [ "$(any_watched_change $'scripts/x.sh' '')" = "0" ]
}

@test "watched_hits: a file named exactly like a dir prefix's parent is not a false hit (#1019)" {
  # 'scripts' (no slash) as a plain file must NOT match the 'scripts/' dir pattern.
  run watched_hits $'scriptsfoo/bar' $'scripts/'
  [ -z "$output" ]
}

# ── autocut: script-only changes must cut (the core #1019 defect) ──
# The reusable blob is byte-identical between `next` and main HEAD, but a scripts/ file changed.
# Autocut MUST still cut a new candidate and move next. The stub returns an identical reusable
# blob at both refs, an empty commits?path list (script-only: no reusable commit), and a compare
# payload carrying the changed file list + the commit messages that drive the bump.
_scriptonly_stub() {
  # args: agent host reusable mainsha nextsha versions compare_json [bump]
  local agent="$1" host="$2" reusable="$3" MAINSHA="$4" NEXTSHA="$5" versions="$6" compare_json="$7" bump="${8:-}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$STUB_BIN/gh-writes.log"; : > "$GH_LOG"
  local refs="" v
  for v in $versions; do refs+="refs/tags/$agent/v$v"$'\n'; done
  printf '%s' "$compare_json" > "$STUB_BIN/compare.json"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *".default_branch"*) echo "main" ;;
  *"compare/"*) cat "$STUB_BIN/compare.json" ;;
  *"/commits"*"-f path="*) echo '[]' ;;
  *"contents/"*"ref=$MAINSHA"*) echo "sameBLOB" ;;
  *"contents/"*"ref=$NEXTSHA"*) echo "sameBLOB" ;;
  *"-X POST"*"git/tags"*) echo "\$*" >> "$GH_LOG"; echo "7a90000000000000000000000000000000000000" ;;
  *"-X PATCH"*"git/refs/tags/"*) echo "\$*" >> "$GH_LOG"; exit 0 ;;
  *"-X POST"*"git/refs"*) echo "\$*" >> "$GH_LOG"; echo "{}" ;;
  *"/commits/"*) echo "$MAINSHA" ;;
  *"matching-refs/tags/$agent/v"*) printf '%s' "$refs" ;;
  *"git/ref/tags/$agent/v"*"-next"*) printf '\n' ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  *"git/ref/tags/$agent/v"*) printf '\n' ;;
  *"run list"*) echo "[]" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse"*"$agent/next"*) echo "$NEXTSHA" ;;
  *) : ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"
  SCRIPTONLY_RINGS="$BATS_TEST_TMPDIR/scriptonly-rings.json"
  if [ -n "$bump" ]; then
    jq --arg a "$agent" --arg b "$bump" \
      '{version, description, org_infra_repos, member_tokens, agent_ref_paths, agents: {($a): (.agents[$a] + {autocut: {bump: $b}})}}' \
      "$RINGS" > "$SCRIPTONLY_RINGS"
  else
    jq --arg a "$agent" \
      '{version, description, org_infra_repos, member_tokens, agent_ref_paths, agents: {($a): .agents[$a]}}' \
      "$RINGS" > "$SCRIPTONLY_RINGS"
  fi
}

@test "orchestrator: autocut cuts on a SCRIPT-ONLY change (reusable blob identical) (#1019)" {
  local compare='{"files":[{"filename":"scripts/lib/dev-lead-retrigger.sh"}],"commits":[{"commit":{"message":"fix: forced dispatches survive sweep concurrency"}}]}'
  _scriptonly_stub persona-mention petry-projects/.github .github/workflows/persona-mention-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "1.2.0" "$compare"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$SCRIPTONLY_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # fix-only script change → patch bump v1.2.0 → v1.2.1, cut on the host + next moved.
  grep -q "repos/petry-projects/.github/git/tags .*tag=persona-mention/v1.2.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github/git/refs/tags/persona-mention/next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut does NOT cut when only a non-watched path changed (#1019)" {
  # reusable identical AND the only change is under docs/ (not scripts/prompts/personas/ or the
  # reusable) → nothing a consumer executes changed → no cut.
  local compare='{"files":[{"filename":"docs/notes.md"}],"commits":[{"commit":{"message":"docs: tidy"}}]}'
  _scriptonly_stub persona-mention petry-projects/.github .github/workflows/persona-mention-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "1.2.0" "$compare"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$SCRIPTONLY_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cut"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "orchestrator: autocut bump detection applies to a script-only feat → MINOR (#1019)" {
  local compare='{"files":[{"filename":"scripts/lib/dev-lead-retrigger.sh"}],"commits":[{"commit":{"message":"feat: add a --force retrigger mode"}}]}'
  _scriptonly_stub persona-mention petry-projects/.github .github/workflows/persona-mention-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "1.2.0" "$compare"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$SCRIPTONLY_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=persona-mention/v1.3.0 " "$GH_LOG"
}

@test "orchestrator: autocut bump detection applies to a script-only feat! → MAJOR (#1019)" {
  local compare='{"files":[{"filename":"scripts/lib/dev-lead-retrigger.sh"}],"commits":[{"commit":{"message":"feat!: drop the legacy retrigger path"}}]}'
  _scriptonly_stub persona-mention petry-projects/.github .github/workflows/persona-mention-reusable.yml \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "1.2.0" "$compare"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$SCRIPTONLY_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # major bump v1.2.0 → v2.0.0 seeded on a fresh v2-next line.
  grep -q "git/tags .*tag=persona-mention/v2.0.0 " "$GH_LOG"
  grep -q "PATCH repos/petry-projects/.github/git/refs/tags/persona-mention/v2-next " "$GH_LOG"
}

# ── _gh_move_tag: create the ref when the PATCH reports 422 "Reference does not exist" ──
# A promotion into a channel that has never been tagged (e.g. persona-mention/ring0,
# apply-repo-settings) PATCHes a nonexistent ref, which GitHub answers 422 "Reference does not
# exist" (NOT 404). The mover must treat that as create-if-missing and POST the ref (#1019).
@test "_gh_move_tag: creates the ref on a 422 'Reference does not exist' (#1019)" {
  _move_tag_stub noref ok
  run bash -c "source '$ORCH' && _gh_move_tag petry-projects/.github persona-mention/ring0 8837cee9db2988837cee9db2988837cee9db298"
  [ "$status" -eq 0 ]
  grep -q '^PATCH$' "$CALL_LOG"
  grep -q '^POST$' "$CALL_LOG"
  [[ "$output" != *"::error::"* ]]
}

# ── promote-all: a per-agent failure it already logged must not take the run red ──
@test "orchestrator: promote-all returns 0 when a per-agent promote fails (continuing fleet) (#1019)" {
  run env CANARY_RINGS="$RINGS" bash -c "
    source '$ORCH'
    cmd_promote() { if [ \"\$1\" = agent-shield ]; then return 3; fi; echo \"promoted \$1\"; return 0; }
    cmd_promote_all
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"promote of agent-shield returned 3 (continuing fleet)"* ]]
}

@test "orchestrator: promote-all names every failed agent in an aggregated summary (#1019)" {
  # The sweep still exits 0 by design, but a green run must not imply "everything
  # promoted": a permission/API rejection has to be visible without reading the whole log.
  run env CANARY_RINGS="$RINGS" bash -c "
    source '$ORCH'
    cmd_promote() { case \"\$1\" in agent-shield) return 3 ;; dev-lead) return 4 ;; *) echo \"promoted \$1\"; return 0 ;; esac; }
    cmd_promote_all
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-shield(3)"* ]]
  [[ "$output" == *"dev-lead(4)"* ]]
  [[ "$output" == *"promote-all summary: 2 failed"* ]]
}

@test "orchestrator: promote-all reports a clean sweep when no agent fails (#1019)" {
  run env CANARY_RINGS="$RINGS" bash -c "
    source '$ORCH'
    cmd_promote() { echo \"promoted \$1\"; return 0; }
    cmd_promote_all
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"promote-all summary: all agents promoted or already current."* ]]
  [[ "$output" != *"failed"* ]]
}

# ── compare-API truncation (#1019) ────────────────────────────────────────────
# The compare API caps `.files` at 300 and sets `.truncated: true`. Reading `.files`
# alone would omit changed paths — and since autocut ships only when a WATCHED path
# changed, an omitted `scripts/…` entry silently skips the cut. Truncation must never
# read as "no change".
@test "_gh_changed_files: unions per-commit files when the compare response is truncated (#1019)" {
  local stub; stub="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$stub:$PATH"
  cat > "$stub/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  */compare/*)
    echo '{"truncated":true,"files":[{"filename":"docs/a.md"}],"commits":[{"sha":"aaa"},{"sha":"bbb"}]}' ;;
  */commits/aaa) echo '{"files":[{"filename":"scripts/engine.sh"},{"filename":"docs/a.md"}]}' ;;
  */commits/bbb) echo '{"files":[{"filename":"prompts/deep-review.md"}]}' ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$stub/gh"
  run bash -c "source '$ORCH'; _gh_changed_files owner/repo base head"
  [ "$status" -eq 0 ]
  # the file the truncated compare DID return is kept …
  [[ "$output" == *"docs/a.md"* ]]
  # … and the watched paths only reachable per-commit are recovered
  [[ "$output" == *"scripts/engine.sh"* ]]
  [[ "$output" == *"prompts/deep-review.md"* ]]
  # deduplicated (docs/a.md appears in both the compare and commit aaa)
  [ "$(printf '%s\n' "$output" | grep -c '^docs/a\.md$')" -eq 1 ]
}

@test "_gh_changed_files: uses the compare file list directly when not truncated (#1019)" {
  local stub; stub="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$stub:$PATH"
  cat > "$stub/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  */compare/*) echo '{"truncated":false,"files":[{"filename":"scripts/only.sh"}],"commits":[{"sha":"aaa"}]}' ;;
  */commits/*) echo '{"files":[{"filename":"SHOULD-NOT-BE-FETCHED"}]}' ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$stub/gh"
  run bash -c "source '$ORCH'; _gh_changed_files owner/repo base head"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/only.sh"* ]]
  [[ "$output" != *"SHOULD-NOT-BE-FETCHED"* ]]
}

# ── enum ↔ registry agreement (a newly registered agent must be dispatchable) ──
@test "canary-rollout.yml: the agent choice list agrees with the registry (#1019)" {
  local wf="$SCRIPT_DIR/.github/workflows/canary-rollout.yml"
  # Extract the `agent:` input's choice options — a YAML block list of `          - <name>`
  # entries under `options:`, bounded to the agent block (stop at the next same-indent key).
  local enum_sorted registry_sorted
  enum_sorted="$(awk '
    /^      agent:/ { in_agent=1; next }
    in_agent && /^      [^[:space:]]/ && !/^      agent:/ { in_agent=0 }
    in_agent && /^        options:/ { in_opts=1; next }
    in_opts && /^          - / { sub(/^          - /, ""); print; next }
    in_opts && /^        [^[:space:]-]/ { in_opts=0 }
  ' "$wf" | sort -u)"
  [ -n "$enum_sorted" ]
  registry_sorted="$(jq -r '.agents|keys[]' "$RINGS" | sort -u)"
  [ "$enum_sorted" = "$registry_sorted" ]
}

# ── pr-review registration (#1166) ──
# pr-review is the ring-0 self-host reviewer (#497): its engine reusable
# `pr-review.yml` lives in .github-private, dogfooded there on `pr-review/next`.
# It was absent from the registry, so autocut never cut/advanced its channel — a
# merged fix sat inert on main until a human ran cut-release.sh. It must be
# registered like the other .github-private-hosted agents (dev-lead,
# ci-failure-analyst): host-relative rings (next = the host) so `next`+`ring0`
# span both org-infra repos whichever hosts the agent.
@test "pr-review is registered with its .github-private host + engine reusable (#1166)" {
  [ "$(jq -r '.agents["pr-review"].host' "$RINGS")" = "petry-projects/.github-private" ]
  [ "$(jq -r '.agents["pr-review"].reusable' "$RINGS")" = ".github/workflows/pr-review.yml" ]
  # run_workflow must resolve the agent's runs for the gate's sample floor — non-empty.
  [ -n "$(jq -r '.agents["pr-review"].run_workflow // empty' "$RINGS")" ]
  # It MUST be the caller stub's DISPLAY NAME, not a *.yml filename. On the outer tiers
  # (.github/TalkTerm/… which have no pr-review workflow) `gh run list --workflow <name>`
  # returns the graceful "could not find any workflows named …" → [] (#747); a *.yml
  # filename instead 404s and _run_json mis-triages that as a transient fetch failure and
  # fails the gate CLOSED. Guard against regressing run_workflow back to a filename.
  [[ "$(jq -r '.agents["pr-review"].run_workflow' "$RINGS")" != *.yml ]]
}

@test "pr-review rings are host-relative next->ring0->ring1->stable (#1166)" {
  # Ordered channels (registry order = tier order).
  [ "$(jq -r '.agents["pr-review"].rings | sort_by(.order) | map(.channel) | join(",")' "$RINGS")" \
      = "next,ring0,ring1,stable" ]
  # next dogfoods on the host itself (the $host token), matching dev-lead/ci-failure-analyst.
  [ "$(jq -r '.agents["pr-review"].rings[] | select(.channel=="next") | .members | join(",")' "$RINGS")" = "\$host" ]
  [ "$(jq -r '.agents["pr-review"].rings[] | select(.channel=="ring0") | .members | join(",")' "$RINGS")" = "\$org_infra" ]
  [ "$(jq -r '.agents["pr-review"].rings[] | select(.channel=="stable") | .members | join(",")' "$RINGS")" = "*" ]
}

@test "canary-rollout.yml: pr-review is a hand-dispatchable agent (#1106 AC3)" {
  local wf="$SCRIPT_DIR/.github/workflows/canary-rollout.yml"
  run grep -Eq '^          - pr-review$' "$wf"
  [ "$status" -eq 0 ]
}

# ── drift: per-agent "merged but not shipped" signal (#1019) ──
# For each agent, drift compares the `next` channel commit against host main HEAD across the
# agent_ref-consumed paths, so "merged but not shipped" is visible without a hand-run git diff.
_shipdrift_stub() {
  # A single cross-repo agent whose next != main and a scripts/ file changed between them.
  local agent="$1" host="$2" NEXTSHA="$3" MAINSHA="$4" compare_json="$5"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '%s' "$compare_json" > "$STUB_BIN/compare.json"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"contents/.github/workflows"*) echo '[]' ;;
  *".default_branch"*) echo "main" ;;
  *"compare/"*) cat "$STUB_BIN/compare.json" ;;
  *"/commits/"*) echo "$MAINSHA" ;;
  *"git/ref/tags/$agent/v"*"-next"*) printf '\n' ;;
  *"git/ref/tags/$agent/next"*) printf '%s\tcommit\n' "$NEXTSHA" ;;
  *"git/ref/tags/$agent/v"*) printf '\n' ;;
  *"matching-refs/tags/$agent/v"*) printf '\n' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # cross-repo agent resolves channel tags via gh api, not git
GITEOF
  chmod +x "$STUB_BIN/git"
  SHIPDRIFT_RINGS="$BATS_TEST_TMPDIR/shipdrift-rings.json"
  jq --arg a "$agent" \
    '{version, description, org_infra_repos, member_tokens, agent_ref_paths, agents: {($a): .agents[$a]}}' \
    "$RINGS" > "$SHIPDRIFT_RINGS"
}

@test "orchestrator: drift reports an agent whose next lags host main across agent_ref paths (#1019)" {
  # persona-mention is cross-repo (host=.github); next resolves via gh api. next != main and a
  # scripts/ file differs between them → merged-but-unshipped.
  local compare='{"files":[{"filename":"scripts/lib/persona-mention.sh"}],"commits":[{"commit":{"message":"fix: x"}}]}'
  _shipdrift_stub persona-mention petry-projects/.github \
    cccccccccccccccccccccccccccccccccccccccc aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$compare"
  # Force THIS_REPO=.github-private so persona-mention (host=.github) is cross-repo and resolves
  # its `next` channel tag via gh api (the stub), not local git (mirrors the #613 cross-repo tests).
  run env GITHUB_REPOSITORY="petry-projects/.github-private" CANARY_RINGS="$SHIPDRIFT_RINGS" bash "$ORCH" drift
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT[unshipped]"* ]]
  [[ "$output" == *"persona-mention"* ]]
  [[ "$output" == *"scripts/"* ]]
}

# ── explicit empty agent_ref_paths override (#1019) ───────────────────────────
# `[]` is an intentional opt-out ("watch only my reusable"); an OMITTED key means
# "use the built-in fallback". Testing the rendered list for emptiness conflates
# the two and silently restores scripts/, prompts/, personas/.
@test "_watched_paths: an explicit empty agent_ref_paths override is honoured (#1019)" {
  local rings="$BATS_TEST_TMPDIR/rings-empty.json"
  cat > "$rings" <<'JSON'
{"agents":{"solo":{"host":"o/r","reusable":".github/workflows/solo-reusable.yml","agent_ref_paths":[]}}}
JSON
  run env CANARY_RINGS="$rings" bash -c "source '$ORCH'; _watched_paths solo"
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/solo-reusable.yml"* ]]
  [[ "$output" != *"scripts/"* ]]
  [[ "$output" != *"prompts/"* ]]
  [[ "$output" != *"personas/"* ]]
}

@test "_watched_paths: an OMITTED agent_ref_paths still falls back to the built-in set (#1019)" {
  local rings="$BATS_TEST_TMPDIR/rings-omit.json"
  cat > "$rings" <<'JSON'
{"agents":{"solo":{"host":"o/r","reusable":".github/workflows/solo-reusable.yml"}}}
JSON
  run env CANARY_RINGS="$rings" bash -c "source '$ORCH'; _watched_paths solo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/"* ]]
  [[ "$output" == *"prompts/"* ]]
  [[ "$output" == *"personas/"* ]]
}

# ══ #1065: channel resolution must key on the CHANNEL major, not the RELEASE major ═══════
# A release-v14 / channel-v1 agent (v14 release line not yet migrated to channel tags) has only
# v1-* channel tags. `_agent_current_major` (the RELEASE major) is 14, but resolution must target
# the tags that EXIST — `<agent>/v1-<tier>` — never a tagless `v14-<tier>` line and never the bare
# tier. Fixture: dev-lead (cross-repo) with release tag v14.0.0 but channel anchors only v1-next /
# v1-ring0; the bare ring0 points elsewhere so a fallback would be detectable.
_divergent_major_stub() {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  local v1next="a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  local v1ring0="d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"
  local barering0="b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v14.0.0\nrefs/tags/dev-lead/v1-next\nrefs/tags/dev-lead/v1-ring0\n' ;;
  *"git/ref/tags/dev-lead/v1-next"*)   echo "$v1next commit" ;;
  *"git/ref/tags/dev-lead/v1-ring0"*)  echo "$v1ring0 commit" ;;
  *"git/ref/tags/dev-lead/v14-"*)      printf '\n' ;;
  *"git/ref/tags/dev-lead/ring0"*)     echo "$barering0 commit" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
: # dev-lead is cross-repo; all tag resolution goes via gh api above
GITEOF
  chmod +x "$STUB_BIN/git"
}

@test "_resolved_channel: release-major≠channel-major resolves to v1-ring0, never v14-ring0 nor bare ring0 (#1065)" {
  _divergent_major_stub
  # cross-repo (host=.github-private, THIS_REPO=.github) so channel tags resolve via gh api.
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _resolved_channel_tag dev-lead ring0"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v1-ring0" ]
  [ "$output" != "dev-lead/v14-ring0" ]
  [ "$output" != "dev-lead/ring0" ]
  # the resolved commit is the v1-ring0 tag's, never the bare ring0's (no fallback).
  run env GITHUB_REPOSITORY="petry-projects/.github" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _resolved_channel dev-lead ring0 | cut -f2"
  [ "$output" = "d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1" ]
  [ "$output" != "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0" ]
}

# ── ADR-0007 collapsed repos: run attribution by ingress JOB (#1224) ──────────
# A collapsed repo replaces its per-role caller stubs with ONE `Agent Ingress` workflow
# carrying one job per role. `gh run list --workflow "Dev-Lead Agent"` then finds nothing
# there, so the gate must fall back to the ingress and attribute each run to the agent's
# role job (registry `ingress_job`). A member whose runs cannot be attributed is reported
# UNRESOLVED and never counts as passing evidence.
#
# _ingress_stub — gh stub for three repos:
#   org/collapsed — no per-role workflows; `Agent Ingress` runs 101,102,104
#   org/legacy    — `Dev-Lead Agent` run 201 (no ingress)
#   org/none      — neither workflow (a non-consumer, #747)
#   org/nojobs    — `Agent Ingress` run 103 whose jobs list is empty (unattributable)
# Every gh invocation is appended to $GH_LOG.
_ingress_stub() {
  # _frontier_state keeps its per-process UNRESOLVED flag under $TMPDIR; scope it to this test.
  export TMPDIR="$BATS_TEST_TMPDIR"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$BATS_TEST_TMPDIR/gh-ingress.log"; : > "$GH_LOG"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
repo=""; wf=""; prev=""
for a in "$@"; do
  [ "$prev" = "--repo" ] && repo="$a"
  [ "$prev" = "--workflow" ] && wf="$a"
  prev="$a"
done
nf() { echo "could not find any workflows named $wf" >&2; exit 1; }
case "$1 $2" in
  "run list")
    case "$repo|$wf" in
      "org/collapsed|Agent Ingress")
        echo '[{"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":101,"workflowName":"Agent Ingress"},
               {"conclusion":"failure","createdAt":"2026-01-02T01:00:00Z","databaseId":102,"workflowName":"Agent Ingress"},
               {"conclusion":"success","createdAt":"2026-01-02T02:00:00Z","databaseId":104,"workflowName":"Agent Ingress"},
               {"conclusion":null,"createdAt":"2026-01-02T03:00:00Z","databaseId":105,"workflowName":"Agent Ingress"}]' ;;
      "org/nojobs|Agent Ingress")
        echo '[{"conclusion":"failure","createdAt":"2026-01-02T00:00:00Z","databaseId":103,"workflowName":"Agent Ingress"}]' ;;
      "org/skipbusy|Agent Ingress")
        # Three runs today in which the dev-lead role job was SKIPPED (other roles' events fired the
        # shared ingress); the cap leaves the newest-but-one unread, so nothing countable is observed.
        t="$(date -u +%Y-%m-%d)"
        echo "[{\"conclusion\":\"success\",\"createdAt\":\"${t}T10:00:00Z\",\"databaseId\":321,\"workflowName\":\"Agent Ingress\"},
               {\"conclusion\":\"success\",\"createdAt\":\"${t}T09:00:00Z\",\"databaseId\":320,\"workflowName\":\"Agent Ingress\"},
               {\"conclusion\":\"success\",\"createdAt\":\"${t}T08:00:00Z\",\"databaseId\":319,\"workflowName\":\"Agent Ingress\"}]" ;;
      "org/preadopt|Agent Ingress")
        echo '[{"conclusion":"success","createdAt":"2026-01-03T00:00:00Z","databaseId":411,"workflowName":"Agent Ingress"},
               {"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":410,"workflowName":"Agent Ingress"}]' ;;
      "org/rolegap|Agent Ingress")
        echo '[{"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":421,"workflowName":"Agent Ingress"},
               {"conclusion":"success","createdAt":"2026-01-03T00:00:00Z","databaseId":422,"workflowName":"Agent Ingress"}]' ;;
      "org/norole|Agent Ingress")
        echo '[{"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":431,"workflowName":"Agent Ingress"}]' ;;
      "org/cancelled|Agent Ingress")
        echo '[{"conclusion":"cancelled","createdAt":"2026-01-02T00:00:00Z","databaseId":441,"workflowName":"Agent Ingress"}]' ;;
      "org/tie|Agent Ingress")
        echo '[{"conclusion":"failure","createdAt":"2026-01-02T00:00:00Z","databaseId":451,"workflowName":"Agent Ingress"},
               {"conclusion":"failure","createdAt":"2026-01-03T00:00:00Z","databaseId":452,"workflowName":"Agent Ingress"}]' ;;
      "org/sfgap|Agent Ingress")
        echo '[{"conclusion":"startup_failure","createdAt":"2026-01-03T00:00:00Z","databaseId":461,"workflowName":"Agent Ingress"},
               {"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":462,"workflowName":"Agent Ingress"}]' ;;
      "org/busy|Agent Ingress")
        # Three attributable runs: two today, one yesterday (newest first once sorted by createdAt).
        t="$(date -u +%Y-%m-%d)"; y="$(date -u -d yesterday +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)"
        echo "[{\"conclusion\":\"success\",\"createdAt\":\"${t}T10:00:00Z\",\"databaseId\":303,\"workflowName\":\"Agent Ingress\"},
               {\"conclusion\":\"success\",\"createdAt\":\"${t}T09:00:00Z\",\"databaseId\":302,\"workflowName\":\"Agent Ingress\"},
               {\"conclusion\":\"success\",\"createdAt\":\"${y}T12:00:00Z\",\"databaseId\":301,\"workflowName\":\"Agent Ingress\"}]" ;;
      "org/legacy|Dev-Lead Agent")
        echo '[{"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":201,"workflowName":"Dev-Lead Agent"}]' ;;
      "org/legacy|CI Failure Analyst")
        echo '[{"conclusion":"success","createdAt":"2026-01-02T00:00:00Z","databaseId":202,"workflowName":"CI Failure Analyst"}]' ;;
      *) nf ;;
    esac ;;
  "run view")
    # Transient/systemic jobs-endpoint failure (5xx) — NOT a permanent 404.
    [ -n "${STUB_JOBS_FAIL:-}" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    case "$3" in
      30[123]) echo '{"jobs":[{"name":"dev-lead / run","conclusion":"success","steps":[]}]}' ;;
      411|421) echo '{"jobs":[{"name":"dev-lead / run","conclusion":"success","steps":[]}]}' ;;
      410|422|431) echo '{"jobs":[{"name":"pr-review / review","conclusion":"success","steps":[]}]}' ;;
      441) echo '{"jobs":[]}' ;;
      461) echo '{"jobs":[]}' ;;
      462) echo '{"jobs":[{"name":"pr-review / review","conclusion":"success","steps":[]}]}' ;;
      # A failed job and an action_required job of the SAME role, in both orders (max_by tie-break).
      451) echo '{"jobs":[{"name":"dev-lead / build","conclusion":"failure","steps":[]},{"name":"dev-lead / approve","conclusion":"action_required","steps":[]}]}' ;;
      452) echo '{"jobs":[{"name":"dev-lead / approve","conclusion":"action_required","steps":[]},{"name":"dev-lead / build","conclusion":"failure","steps":[]}]}' ;;
      32[01]) echo '{"jobs":[{"name":"dev-lead / run","conclusion":"skipped","steps":[]},{"name":"pr-review / review","conclusion":"success","steps":[]}]}' ;;
      101) echo '{"jobs":[{"name":"dev-lead / run","conclusion":"success","steps":[]},
                          {"name":"pr-review / review","conclusion":"failure","steps":[{"name":"Push","conclusion":"failure"}]},
                          {"name":"ci-failure-analyst","conclusion":"skipped","steps":[]}]}' ;;
      102) echo '{"jobs":[{"name":"dev-lead / setup","conclusion":"success","steps":[]},
                          {"name":"dev-lead / run","conclusion":"failure","steps":[{"name":"Build","conclusion":"failure"}]},
                          {"name":"pr-review / review","conclusion":"failure","steps":[{"name":"Push","conclusion":"failure"}]},
                          {"name":"ci-failure-analyst","conclusion":"skipped","steps":[]}]}' ;;
      103) echo '{"jobs":[]}' ;;
      104) echo '{"jobs":[{"name":"dev-lead / run","conclusion":"skipped","steps":[]},
                          {"name":"ci-failure-analyst / analyse","conclusion":"success","steps":[]}]}' ;;
      *) echo "run $3 not found" >&2; exit 1 ;;
    esac ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
  # Test registry: dev-lead (ingress_job registered) + `noingress` (same per-role workflow, NO
  # ingress_job) + `cfa` (ingress_job ci-failure-analyst). Each takes members from its rings.
  INGRESS_RINGS="$BATS_TEST_TMPDIR/ingress-rings.json"
  jq '{org_infra_repos, ingress,
       agents: {
         "dev-lead": (.agents["dev-lead"] | .ingress_job = "dev-lead"),
         "noingress": (.agents["dev-lead"] | del(.ingress_job) | .gate.benign_failure_classes = []
                       | .gate.suspect_failure_classes = [] | del(.gate.correctness)
                       | .rings = [{"channel":"next","order":0,"members":["org/collapsed"]},
                                   {"channel":"ring0","order":1,"members":["org/legacy"]}]
                       | .gate.transitions = {"next->ring0":{"dwell_hours":0,"waive_sample":true}}),
         "cfa": (.agents["dev-lead"] | .ingress_job = "ci-failure-analyst" | .run_workflow = "CI Failure Analyst" | .gate.benign_failure_classes = []
                 | .gate.suspect_failure_classes = [] | del(.gate.correctness)
                 | .rings = [{"channel":"next","order":0,"members":["org/collapsed"]},
                             {"channel":"ring0","order":1,"members":["org/legacy"]}]
                 | .gate.transitions = {"next->ring0":{"dwell_hours":0,"waive_sample":true}})
       }}' "$RINGS" > "$INGRESS_RINGS"
  export INGRESS_RINGS
}

@test "_agent_run_json: a collapsed repo (ingress role job, no per-role workflow) resolves by JOB (#1224)" {
  _ingress_stub
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH' && _agent_run_json dev-lead org/collapsed '' | jq -c 'sort_by(.databaseId)|map([.databaseId,.conclusion,.workflowName,.role])'"
  [ "$status" -eq 0 ]
  # 101 → dev-lead success; 102 → dev-lead failure (worst-outcome over its two jobs);
  # 104 → dev-lead skipped = did not run (no record); 105 → in flight (no record).
  [ "$output" = '[[101,"success","Dev-Lead Agent","dev-lead"],[102,"failure","Dev-Lead Agent","dev-lead"]]' ]
}

@test "_agent_run_json: a non-collapsed repo still resolves by workflow name and never queries the ingress (#1224)" {
  _ingress_stub
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH' && _agent_run_json dev-lead org/legacy '' | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]
  [ "$output" = "[201]" ]
  run grep -q "Agent Ingress" "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "_agent_run_json: a repo with neither workflow nor ingress is a non-consumer [] — not unresolved (#747 preserved, #1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _agent_run_json noingress org/none ''"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ ! -s "$flag" ]
}

@test "_agent_run_json: ingress present but the agent has no ingress_job → member reported UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _agent_run_json noingress org/collapsed ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNRESOLVED"* ]]
  [[ "$output" == *"org/collapsed"* ]]
  grep -q "^org/collapsed" "$flag"
}

@test "_agent_run_json: CANARY_INGRESS_JOBS_MAX caps newest-first job reads and flags the member UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 CANARY_INGRESS_JOBS_MAX=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/collapsed '' 2>/dev/null | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]
  # Newest completed run is 104 (dev-lead skipped → no record); the cap then stops further reads.
  [ "$output" = '[]' ]
  grep -q "more than 1 ingress runs" "$flag"
  grep -q "run view 104 " "$GH_LOG"
  ! grep -q "run view 102 " "$GH_LOG"
  ! grep -q "run view 101 " "$GH_LOG"
}

@test "_baseline_daily: a capped ingress read is a valid truncated sample of the NEWEST days, not UNRESOLVED (#1224 liveness)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # org/busy has 3 attributable runs (2 today, 1 yesterday); the cap of 2 leaves yesterday's run
  # unread. The baseline must cover TODAY only (yesterday and older are unknown, not zero) and the
  # member must NOT be flagged UNRESOLVED — a busy collapsed repo may not hold the gate forever.
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 CANARY_INGRESS_JOBS_MAX=2 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _baseline_daily dev-lead 3 org/busy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ ! -s "$flag" ]
}

@test "_baseline_daily: more runs on the NEWEST day than the cap keeps that day's partial count, never an empty baseline (#1224 liveness)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # Cap of 1: only run 303 (today) is read; the first unread run (302) is also today, so today is the
  # boundary day. Its partial count (1) is a lower bound and must be kept — dropping it would leave an
  # empty baseline that waive_sample_if_no_caller reads as "no caller".
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 CANARY_INGRESS_JOBS_MAX=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _baseline_daily dev-lead 3 org/busy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ ! -s "$flag" ]
}

@test "_baseline_daily: a truncated read that observed NOTHING countable is a non-zero floor, never 'no caller' (#1224 liveness)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 CANARY_INGRESS_JOBS_MAX=2 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _baseline_daily dev-lead 3 org/skipbusy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ ! -s "$flag" ]
}

@test "_baseline_daily: truncation is per repo — a fully-read member keeps its older days known beside a capped one (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # org/busy is capped to TODAY (older days unknown for it); org/legacy is read completely, so the
  # older days are known (zero) for the aggregate and must not be dropped by busy's cutoff.
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 CANARY_INGRESS_JOBS_MAX=2 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _baseline_daily dev-lead 3 org/busy org/legacy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2 0 0" ]
  [ ! -s "$flag" ]
}

@test "_baseline_daily: an UNCAPPED baseline still reports every day (zero-filled), nothing dropped (#1224 liveness)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 CANARY_INGRESS_JOBS_MAX=300 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _baseline_daily dev-lead 3 org/busy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2 1 0" ]
  [ ! -s "$flag" ]
}

@test "_run_decision_class: a transient jobs-read failure is recorded UNRESOLVED, not read as 'no decision step' (#1244 item 3)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env STUB_JOBS_FAIL=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _run_decision_class org/legacy 201 'decision: ' '' dev-lead 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "^org/legacy" "$flag"
  grep -q "decision mix" "$flag"
}

@test "_run_decision_class: a failed read is NOT memoized — a same-sweep re-read fails again instead of reading as 'no decision step' (#1250 review)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env STUB_JOBS_FAIL=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e
      _run_decision_class org/legacy 201 'decision: ' '' dev-lead >/dev/null 2>&1; r1=\$?
      _run_decision_class org/legacy 201 'decision: ' '' dev-lead >/dev/null 2>&1; r2=\$?
      echo \"\$r1 \$r2\""
  [ "$status" -eq 0 ]
  # A cached empty class would make the second call return 0.
  [ "$output" = "1 1" ]
}

@test "_agent_run_json: an invalid CANARY_INGRESS_RUN_LIMIT is normalized before the fetch, not sent to gh (#1250 review)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_INGRESS_RUN_LIMIT=abc CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '' | jq -c 'map(.databaseId)|sort'"
  [ "$status" -eq 0 ]
  [ "$output" = "[301,302,303]" ]
  grep -q -- "-L 5000" "$GH_LOG"
  ! grep -q -- "-L abc" "$GH_LOG"
}

@test "_run_decision_class: a permanently gone run (404) is expected — contributes nothing, not UNRESOLVED (#1244 item 3)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _run_decision_class org/legacy 999 'decision: ' '' dev-lead 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$flag" ]
}

@test "_sample_decision_counts: a sustained jobs outage marks the member UNRESOLVED instead of silently thinning the mix (#1244 item 3)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env STUB_JOBS_FAIL=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _sample_decision_counts dev-lead 'decision: ' 5 '' '-' org/legacy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  grep -q "^org/legacy" "$flag"
}

@test "_agent_run_json: an ingress run list that hit CANARY_INGRESS_RUN_LIMIT before the window start is UNRESOLVED (#1244 item 11)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # org/busy lists 3 runs; a limit of 3 means the list may have been cut off. With no lower bound on
  # the window it cannot be shown to reach back far enough, so the member is UNRESOLVED (fail closed).
  run env CANARY_INGRESS_RUN_LIMIT=3 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '' 2>/dev/null"
  [ "$status" -eq 0 ]
  grep -q "CANARY_INGRESS_RUN_LIMIT" "$flag"
}

@test "_agent_run_json: a run list at its cap that reaches back BEFORE the window start is complete — not UNRESOLVED (#1244 item 11)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # The window starts today; the list's oldest run is from yesterday, so nothing in-window can be missing.
  local since; since="$(date -u +%Y-%m-%dT00:00:00Z)"
  run env CANARY_INGRESS_RUN_LIMIT=3 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '$since' | jq -c 'map(.databaseId)|sort'"
  [ "$status" -eq 0 ]
  [ "$output" = "[302,303]" ]
  [ ! -s "$flag" ]
}

@test "_agent_run_json: the capped-list completeness check holds for a non-midnight since, and is conservative on an exact tie (#1250 review)" {
  _ingress_stub
  local y; y="$(date -u -d yesterday +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)"
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # org/busy's oldest listed run is yesterday 12:00:00Z (run 301). since and gh's createdAt are both
  # Zulu ISO-8601, so the lexicographic comparison is sound at any time of day, not just midnight.
  # since = yesterday 13:00:00Z is AFTER the oldest listed run → the capped list reaches back far
  # enough: complete, not UNRESOLVED; only the two runs from today are in the window.
  run env CANARY_INGRESS_RUN_LIMIT=3 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '${y}T13:00:00Z' | jq -c 'map(.databaseId)|sort'"
  [ "$status" -eq 0 ]
  [ "$output" = "[302,303]" ]
  [ ! -s "$flag" ]
  # since exactly equal to the oldest listed run does not PROVE the list reaches back before the window:
  # stay conservative (UNRESOLVED), never fail open.
  : > "$flag"
  run env CANARY_INGRESS_RUN_LIMIT=3 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '${y}T12:00:00Z' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  grep -q "CANARY_INGRESS_RUN_LIMIT" "$flag"
}

@test "_baseline_daily: a run list at its cap is a valid sample of the NEWEST days, not UNRESOLVED (#1244 item 11)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # Same shape as the jobs-cap baseline: the oldest listed day (yesterday) is the boundary and is kept
  # because it has observed runs; anything older is unknown, not zero.
  run env CANARY_INGRESS_RUN_LIMIT=3 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; _baseline_daily dev-lead 3 org/busy 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "2 1" ]
  [ ! -s "$flag" ]
}

@test "_agent_run_json: a non-array ingress run list is a failed fetch, not 'no caller' (#1250 review, #1244 item 15)" {
  _ingress_stub
  local d2; d2="$(mktemp -d "$BATS_TEST_TMPDIR/stub3.XXXXXX")"; export PATH="$d2:$PATH"
  cat > "$d2/gh" <<'GHEOF'
#!/usr/bin/env bash
wf=""; prev=""
for a in "$@"; do [ "$prev" = "--workflow" ] && wf="$a"; prev="$a"; done
case "$1 $2" in
  "run list")
    case "$wf" in
      "Agent Ingress") echo '{"message":"unexpected body"}' ;;
      *) echo "could not find any workflows named $wf" >&2; exit 1 ;;
    esac ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$d2/gh"
  # The shared reader rejects a non-array 2xx body (retry, then fail closed with the fetch-failure flag), so
  # the ingress read can no longer be mistaken for an empty window.
  local ff="$BATS_TEST_TMPDIR/fetchfail"; : > "$ff"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_FETCH_FAIL_FLAG="$ff" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/weird '' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$output" != "[]" ]
  grep -q "org/weird" "$ff"
}

@test "_repo_wf_runs_cached: a non-array 2xx body on the legacy per-role path fails closed, never reads as 'no runs' (#1244 item 15)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho '"'"'{"message":"oops"}'"'"'\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  local cache="$BATS_TEST_TMPDIR/rc-nonarray"; mkdir -p "$cache"
  run env _RUNS_CACHE_DIR="$cache" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 \
    bash -c "source '$ORCH'; _run_json some/repo some-wf ''"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$cache")" ]                      # the bad body is never cached
  # A valid empty array is still "no runs".
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$STUB_BIN/gh"
  run env _RUNS_CACHE_DIR="$cache" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=2 \
    bash -c "source '$ORCH'; _run_json some/repo some-wf ''"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "candidate_cut_date: the local-host fallback is normalised to Zulu (#1244 item 17)" {
  local repo="$BATS_TEST_TMPDIR/cutrepo"; git init -q "$repo"
  # A committer date carrying a non-Zulu offset: %cI would print it verbatim.
  GIT_COMMITTER_DATE="2026-03-04T10:00:00+05:00" git -C "$repo" -c user.name=t -c user.email=t@t \
    commit -q --allow-empty -m c
  [ "$(git -C "$repo" log -1 --format=%cI)" = "2026-03-04T10:00:00+05:00" ]
  local sha; sha="$(git -C "$repo" rev-parse HEAD)"
  # Host == this repo and no release tags, so the last-resort local fallback is the path under test.
  run env CANARY_RINGS="$RINGS" bash -c "cd '$repo' && source '$ORCH' && THIS_REPO=\"\$(_agent_field dev-lead host)\" candidate_cut_date dev-lead '$sha'"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-03-04T05:00:00Z" ]
}

@test "_agent_run_json: a job-less cancelled run is tolerated like an in-flight run — its jobs are re-read next sweep and the failure is then attributed (#1244 item 12)" {
  _ingress_stub
  local d2; d2="$(mktemp -d "$BATS_TEST_TMPDIR/stub2.XXXXXX")"; export PATH="$d2:$PATH"
  export LAGFILE="$BATS_TEST_TMPDIR/lag-count"; : > "$LAGFILE"
  cat > "$d2/gh" <<'GHEOF'
#!/usr/bin/env bash
wf=""; prev=""
for a in "$@"; do [ "$prev" = "--workflow" ] && wf="$a"; prev="$a"; done
case "$1 $2" in
  "run list")
    case "$wf" in
      "Agent Ingress") echo '[{"conclusion":"cancelled","createdAt":"2026-01-02T00:00:00Z","databaseId":701,"workflowName":"Agent Ingress"}]' ;;
      *) echo "could not find any workflows named $wf" >&2; exit 1 ;;
    esac ;;
  "run view")
    n="$(cat "$LAGFILE" 2>/dev/null)"; n="${n:-0}"; echo $((n + 1)) > "$LAGFILE"
    # First read: the jobs are not recorded yet (lag). Later reads: the role's job, which FAILED.
    if [ "$n" -eq 0 ]; then echo '{"jobs":[]}'
    else echo '{"jobs":[{"name":"dev-lead / run","conclusion":"failure","steps":[]}]}'; fi ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$d2/gh"
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" LAGFILE="$LAGFILE" \
    bash -c "source '$ORCH'; set +e
      echo \"sweep1: \$(_agent_run_json dev-lead org/lag '' 2>/dev/null | jq -c 'map(.conclusion)')\"
      echo \"sweep2: \$(_agent_run_json dev-lead org/lag '' 2>/dev/null | jq -c 'map(.conclusion)')\""
  [ "$status" -eq 0 ]
  # Sweep 1: nothing recorded and NOT unresolved (same as an in-flight run). Sweep 2: the failure shows.
  [[ "$output" == *"sweep1: []"* ]]
  [[ "$output" == *'sweep2: ["failure"]'* ]]
  [ ! -s "$flag" ]
}

@test "_pair_state: the cut-date early return emits the full 18-field state line (#1244 item 13)" {
  run bash -c "source '$ORCH'; set +e; candidate_cut_date() { echo ''; }; _pair_state dev-lead next ring0 abc1234 'next->ring0' 'next,ring0,ring1,stable' 'abc1234,-,-,-' 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == "abc1234 ring0 next->ring0 BLOCKED "* ]]
  # cmd_sync_issues appends the datagap field, so a short line would shift it into `downgrade`.
  [ "$(wc -w <<< "$output")" -eq 18 ]
  [ "$(awk '{print $12}' <<< "$output")" = "-" ]
}

@test "registry preload: every memoized lookup equals the jq lookup it replaces, for EVERY agent in the real registry (#1259)" {
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH'; set +e
    declare -A exp_wf exp_job
    for a in \$(jq -r '.agents | keys[]' \"\$CANARY_RINGS\"); do
      exp_wf[\$a]=\"\$(_agent_field \"\$a\" run_workflow)\"
      exp_job[\$a]=\"\$(_jq -r --arg a \"\$a\" '(.agents[\$a].ingress_job)? // empty')\"
    done
    exp_iwf=\"\$(_ingress_workflow)\"; exp_missing_wf=\"\$(_agent_field no-such-agent run_workflow)\"
    _registry_preload || { echo PRELOAD_FAILED; exit 1; }
    bad=0; n=0
    for a in \"\${!exp_wf[@]}\"; do
      n=\$((n+1))
      _reg_run_workflow \"\$a\"; [ \"\$_REG_VAL\" = \"\${exp_wf[\$a]}\" ] || { echo \"WF MISMATCH \$a: '\$_REG_VAL' vs '\${exp_wf[\$a]}'\"; bad=1; }
      _reg_ingress_job \"\$a\";  [ \"\$_REG_VAL\" = \"\${exp_job[\$a]}\" ] || { echo \"JOB MISMATCH \$a: '\$_REG_VAL' vs '\${exp_job[\$a]}'\"; bad=1; }
    done
    _reg_ingress_wf; [ \"\$_REG_VAL\" = \"\$exp_iwf\" ] || { echo \"INGRESS WF MISMATCH\"; bad=1; }
    [ \"\$(_ingress_workflow)\" = \"\$exp_iwf\" ] || { echo \"_ingress_workflow MISMATCH\"; bad=1; }
    _reg_run_workflow no-such-agent; [ \"\$_REG_VAL\" = \"\$exp_missing_wf\" ] || { echo \"MISSING AGENT MISMATCH: '\$_REG_VAL' vs '\$exp_missing_wf'\"; bad=1; }
    _reg_ingress_job no-such-agent; [ -z \"\$_REG_VAL\" ] || { echo \"MISSING JOB NOT EMPTY\"; bad=1; }
    echo \"agents=\$n bad=\$bad\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"bad=0"* ]]
  # The registry has many agents; make sure the comparison was not vacuous.
  [[ "$output" =~ agents=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -ge 10 ]
}

@test "registry preload: a map built for one registry is ignored once CANARY_RINGS points elsewhere (#1259)" {
  local other="$BATS_TEST_TMPDIR/other-rings.json"
  jq '.agents["dev-lead"].run_workflow = "Changed Workflow Name" | .ingress.workflow = "Changed Ingress"' "$RINGS" > "$other"
  run env CANARY_RINGS="$RINGS" bash -c "source '$ORCH'; set +e
    _registry_preload
    _reg_run_workflow dev-lead; before=\"\$_REG_VAL\"; _reg_ingress_wf; before_i=\"\$_REG_VAL\"
    export CANARY_RINGS='$other'
    _reg_run_workflow dev-lead; after=\"\$_REG_VAL\"; _reg_ingress_wf; after_i=\"\$_REG_VAL\"
    echo \"\$before|\$after|\$before_i|\$after_i\""
  [ "$status" -eq 0 ]
  [ "$output" != "" ]
  [[ "$output" == *"|Changed Workflow Name|"* ]]
  [[ "$output" == *"|Changed Ingress" ]]
  [[ "$output" != "Changed Workflow Name|"* ]]
}

@test "hot path: a cached non-consumer lookup forks no jq and makes no gh call once the registry is preloaded (#1259)" {
  _ingress_stub
  local real_jq shim; real_jq="$(command -v jq)"
  shim="$(mktemp -d "$BATS_TEST_TMPDIR/jqshim.XXXXXX")"
  export JQ_LOG="$BATS_TEST_TMPDIR/jq.log"; : > "$JQ_LOG"
  printf '#!/usr/bin/env bash\necho "$*" >> "$JQ_LOG"\nexec %q "$@"\n' "$real_jq" > "$shim/jq"; chmod +x "$shim/jq"
  export PATH="$shim:$PATH"
  local cache="$BATS_TEST_TMPDIR/cache-hot"; mkdir -p "$cache"
  # PRELOADED: after the first (cache-priming) call, repeat calls cost no jq and no gh at all.
  run env _RUNS_CACHE_DIR="$cache" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e; _registry_preload
    _agent_run_json dev-lead org/none '' >/dev/null 2>&1
    : > '$JQ_LOG'; : > '$GH_LOG'
    for i in 1 2 3; do out=\"\$(_agent_run_json dev-lead org/none '' 2>/dev/null)\"; [ \"\$out\" = '[]' ] || echo \"BAD:\$out\"; done
    echo \"jq=\$(wc -l < '$JQ_LOG' | tr -d ' ') gh=\$(wc -l < '$GH_LOG' | tr -d ' ')\""
  [ "$status" -eq 0 ]
  [ "$output" = "jq=0 gh=0" ]
  # CONTROL (not preloaded): the same calls DO parse the registry, so the assertion above is not vacuous.
  cache="$BATS_TEST_TMPDIR/cache-hot-control"; mkdir -p "$cache"
  run env -u CANARY_PRELOAD_REGISTRY _RUNS_CACHE_DIR="$cache" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e
    _agent_run_json dev-lead org/none '' >/dev/null 2>&1
    : > '$JQ_LOG'
    out=\"\$(_agent_run_json dev-lead org/none '' 2>/dev/null)\"
    echo \"jq=\$(wc -l < '$JQ_LOG' | tr -d ' ')\""
  [ "$status" -eq 0 ]
  [ "$output" != "jq=0" ]
}

@test "_cache_name: a fork-free, filesystem-safe, INJECTIVE encoding (A B vs A/B, multibyte, long keys) (#1259)" {
  run bash -c "source '$ORCH'; set +e
    declare -A seen; bad=0
    for k in 'org/r//A B//1000' 'org/r//A/B//1000' 'org/r//A_B//1000' 'org/r//A%20B//1000' 'org/r//A+B//1000' \
             'org/r//PR Review — Mention Trigger//1000' 'org/r//PR Review - Mention Trigger//1000' \
             'jobs//org/r//123' 'org/r//jobs//123' '' '-' '.' '..' 'a' 'A' 'h_abc' 'h%5Fabc'; do
      _cache_name \"\$k\"; n=\"\$_CACHE_NAME\"
      [[ \"\$n\" =~ ^[A-Za-z0-9.%_-]*\$ ]] || { echo \"UNSAFE:[\$k]\"; bad=1; }
      [ -z \"\${seen[n:\$n]+x}\" ] || { echo \"COLLIDE:[\$k] vs [\${seen[n:\$n]}]\"; bad=1; }   # n: prefix: bash rejects an empty assoc subscript
      seen[\"n:\$n\"]=\"\$k\"
    done
    _cache_name 'x — y'; case \"\$_CACHE_NAME\" in *%E2%80%94*) ;; *) echo \"EMDASH NOT BYTE-ENCODED: \$_CACHE_NAME\"; bad=1 ;; esac
    long1=\$(printf 'x%.0s' {1..300}); long2=\"\${long1}y\"
    _cache_name \"\$long1\"; l1=\"\$_CACHE_NAME\"; _cache_name \"\$long2\"; l2=\"\$_CACHE_NAME\"
    [ \"\${#l1}\" -le 80 ] && [ \"\${l1:0:2}\" = h_ ] || { echo \"LONG KEY NOT HASHED: \${#l1} \$l1\"; bad=1; }
    [ \"\$l1\" != \"\$l2\" ] || { echo 'LONG KEYS COLLIDE'; bad=1; }
    echo bad=\$bad"
  [ "$status" -eq 0 ]
  [ "$output" = "bad=0" ]
}

@test "_cat_file: byte-identical to cat on both sides of the in-shell threshold, unicode and trailing newlines included (#1259)" {
  local d="$BATS_TEST_TMPDIR/catfiles"; mkdir -p "$d"
  printf '[]' > "$d/tiny"
  local n
  for n in 63 64 65 4096; do head -c "$n" /dev/zero | tr '\0' 'a' > "$d/b$n"; done
  head -c 300000 /dev/zero | tr '\0' 'z' > "$d/big"
  printf 'caf\xc3\xa9 \xe2\x80\x94 "q" \\\\ \n  spaced  ' > "$d/uni"
  printf 'line1\nline2\n\n\n' > "$d/trailing-newlines"
  run bash -c "source '$ORCH'; set +e; bad=0
    for f in tiny b63 b64 b65 b4096 big uni trailing-newlines; do
      a=\"\$(_cat_file '$d'/\$f | od -An -tx1 | tr -d ' \n' | cksum)\"; b=\"\$(cat '$d'/\$f | od -An -tx1 | tr -d ' \n' | cksum)\"
      [ \"\$a\" = \"\$b\" ] || { echo \"DIFFERENT: \$f\"; bad=1; }
    done
    echo bad=\$bad"
  [ "$status" -eq 0 ]
  [ "$output" = "bad=0" ]
}

@test "_repo_wf_runs_cached: a cache hit returns the cached bytes exactly — unicode, quotes, backslashes (#1259)" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/rt-calls"; : > "$CALLS"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
printf '%s' '[{"conclusion":"success","createdAt":"2026-01-10T00:00:00Z","databaseId":1,"workflowName":"PR Review — \"Trigger\" \\ back\\slash  "}]'
GHEOF
  chmod +x "$STUB_BIN/gh"
  run env _RUNS_CACHE_DIR="$BATS_TEST_TMPDIR/rc-bytes" bash -c "
    mkdir -p \"\$_RUNS_CACHE_DIR\"; source '$ORCH'; set +e
    live=\"\$(_repo_wf_runs_cached some/repo 'PR Review — Trigger' 0)\"
    hit=\"\$(_repo_wf_runs_cached some/repo 'PR Review — Trigger' 0)\"
    [ \"\$live\" = \"\$hit\" ] && echo SAME || echo DIFFERENT
    printf '%s' \"\$hit\" | jq -r '.[0].workflowName'
    echo \"calls=\$(wc -l < '$CALLS' | tr -d ' ')\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"SAME"* ]]
  [[ "$output" == *'PR Review — "Trigger" \ back\slash  '* ]]
  [[ "$output" == *"calls=1"* ]]
}

@test "CANARY_TIMING: auto mode is on only for scheduled/dispatched runs in Actions; 1 and 0 override (#1259)" {
  chk() { env -u CANARY_TIMING -u GITHUB_ACTIONS -u GITHUB_EVENT_NAME "$@" bash -c "source '$ORCH'; set +e; _timing_enabled && echo on || echo off"; }
  [ "$(chk)" = "off" ]                                                                   # local / tests
  [ "$(chk GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request)" = "off" ]                # CI test runs
  [ "$(chk GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push)" = "off" ]
  [ "$(chk GITHUB_ACTIONS=true GITHUB_EVENT_NAME=schedule)" = "on" ]                     # the cron sweep
  [ "$(chk GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch)" = "on" ]
  [ "$(chk CANARY_TIMING=1)" = "on" ]                                                    # forced on
  [ "$(chk CANARY_TIMING=0 GITHUB_ACTIONS=true GITHUB_EVENT_NAME=schedule)" = "off" ]    # forced off
}

@test "CANARY_TIMING: the report counts gh calls and agent_run_json calls and writes the step summary (#1259)" {
  _ingress_stub
  run env CANARY_TIMING=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" bash -c "
    source '$ORCH'; set +e
    export _RUNS_CACHE_DIR=\"\$(mktemp -d)\"; _TIMING_SUB=smoke; _registry_preload; _timing_start
    for r in a b c; do _agent_run_json dev-lead org/\$r '' >/dev/null 2>&1; done
    _timing_report 2>&1 >/dev/null
    rm -rf \"\$_RUNS_CACHE_DIR\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"canary timing [smoke]:"* ]]
  [[ "$output" == *"gh_calls=6"* ]]                   # per-role + ingress lookup for each of 3 repos
  [[ "$output" == *"agent_run_json_calls=3"* ]]
  [[ "$output" == *"run list"* ]]
  grep -q "canary timing (smoke)" "$BATS_TEST_TMPDIR/summary.md"
}

@test "_registry_preload: a delimiter in a registry value refuses the preload, and a failed reload drops the stale memo (#1259)" {
  local good="$BATS_TEST_TMPDIR/good.json" bad="$BATS_TEST_TMPDIR/bad.json"
  printf '%s' '{"ingress":{"workflow":"Agent Ingress"},"agents":{"a":{"run_workflow":"A"},"b":{"run_workflow":"B"}}}' > "$good"
  jq -n '{ingress:{workflow:"Agent Ingress"},agents:{a:{run_workflow:"A\u001fX"},b:{run_workflow:"B"}}}' > "$bad"
  jq -n '{ingress:{workflow:"Agent Ingress"},agents:{a:{run_workflow:"line1\nline2"}}}' > "$BATS_TEST_TMPDIR/nl.json"
  run env CANARY_RINGS="$bad" bash -c "source '$ORCH'; _registry_preload && echo loaded || echo refused"
  [ "$output" = "refused" ]
  run env CANARY_RINGS="$BATS_TEST_TMPDIR/nl.json" bash -c "source '$ORCH'; _registry_preload && echo loaded || echo refused"
  [ "$output" = "refused" ]
  # good load, then a failing reload of the SAME path (made unreadable) must not leave the old arrays served
  run env CANARY_RINGS="$good" bash -c "source '$ORCH'; _registry_preload || exit 9
    _reg_run_workflow a; echo \"\$_REG_VAL\"
    CANARY_RINGS='$bad'; _registry_preload || true; echo \"loaded_for=[\$_REG_LOADED_FOR]\"
    CANARY_RINGS='$good'; _registry_preload || true; CANARY_RINGS='$BATS_TEST_TMPDIR/missing.json'; _registry_preload || echo reload_failed
    echo \"loaded_for=[\$_REG_LOADED_FOR]\""
  [ "${lines[0]}" = "A" ]
  [ "${lines[1]}" = "loaded_for=[]" ]
  [[ "$output" == *"reload_failed"* ]]
  [ "${lines[3]}" = "loaded_for=[]" ]
}

@test "_cache_name: with no hasher installed, long keys keep their full (injective) encoding instead of an abbreviated name (#1259)" {
  run bash -c "source '$ORCH'
    sha256sum() { return 127; }; shasum() { return 127; }
    long1=\$(printf 'x%.0s' {1..300}); long2=\"\${long1}y\"
    _cache_name \"\$long1\"; a=\$_CACHE_NAME; _cache_name \"\$long2\"; b=\$_CACHE_NAME
    [ \"\$a\" != \"\$b\" ] && [ \"\$a\" = \"\$long1\" ] && [ \"\$b\" = \"\$long2\" ] && echo distinct"
  [ "$output" = "distinct" ]
}

@test "_ingress_horizon: snaps a window start to a fixed tier of days, or to no bound (#1259)" {
  run bash -c "source '$ORCH'
    d() { date -u -d \"-\$1 days\" +%Y-%m-%d; }
    h() { _ingress_horizon \"\$1\"; echo \"[\$_INGRESS_FROM]\"; }
    echo \"today=\$(h \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\") want=[\$(d 8)]\"
    echo \"d3=\$(h \"\$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)\") want=[\$(d 8)]\"
    echo \"d10=\$(h \"\$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%SZ)\") want=[\$(d 15)]\"
    echo \"d14=\$(h \"\$(date -u -d '-14 days' +%Y-%m-%dT%H:%M:%SZ)\") want=[\$(d 15)]\"
    echo \"d30=\$(h \"\$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)\") want=[]\"
    echo \"empty=\$(h '') want=[]\"
    echo \"junk=\$(h 'not-a-date') want=[]\"
    echo \"empty_tiers=\$(CANARY_INGRESS_HORIZON_TIERS='' h \"\$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)\") want=[]\"
    echo \"tiers=\$(CANARY_INGRESS_HORIZON_TIERS='x 3 40' h \"\$(date -u -d '-20 days' +%Y-%m-%dT%H:%M:%SZ)\") want=[\$(d 40)]\""
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    got="${line#*=}"; got="${got%% want=*}"; want="${line##* want=}"
    [ "$got" = "$want" ] || { echo "mismatch: $line"; return 1; }
  done <<< "$output"
}

@test "_ingress_horizon: the bound always reaches back at least to the window start (#1259)" {
  # Whatever tier is chosen, the horizon date must not be later than the window start's date.
  run bash -c "source '$ORCH'
    for n in 0 1 2 5 7 8 9 13 14 15; do
      since=\$(date -u -d \"-\$n days\" +%Y-%m-%dT%H:%M:%SZ)
      _ingress_horizon \"\$since\"
      [ -z \"\$_INGRESS_FROM\" ] || [[ \"\$_INGRESS_FROM\" < \"\${since:0:10}\" || \"\$_INGRESS_FROM\" = \"\${since:0:10}\" ]] || echo \"BAD n=\$n from=\$_INGRESS_FROM since=\$since\"
    done; echo done"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "_agent_run_json: the ingress run list is date-bounded for a recent window and unbounded for an old or empty one (#1259)" {
  _ingress_stub
  local recent old; recent="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"; old="2026-01-01T00:00:00Z"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e
    _agent_run_json dev-lead org/busy '$recent' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  local from; from="$(date -u -d '-8 days' +%Y-%m-%d)"
  grep -q -- "run list --repo org/busy --workflow Agent Ingress -L 5000 --created >=$from " "$GH_LOG"
  # the per-role workflow lookup is date-bounded too, to its own single 15-day tier (#1259 option B; it was unbounded
  # before — this assertion is flipped deliberately)
  run grep -- "--workflow Dev-Lead Agent" "$GH_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--created >=$(date -u -d '-15 days' +%Y-%m-%d)"* ]]
  : > "$GH_LOG"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e
    _agent_run_json dev-lead org/busy '$old' >/dev/null 2>&1
    _agent_run_json dev-lead org/nojobs '' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  grep -q -- "--workflow Agent Ingress -L 5000 --json" "$GH_LOG"
  run grep -q -- "--created" "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "_agent_run_json: bounded ingress lists are cached per bound; windows in the same tier share one fetch (#1259)" {
  _ingress_stub
  export _RUNS_CACHE_DIR="$BATS_TEST_TMPDIR/cache"; mkdir -p "$_RUNS_CACHE_DIR"
  local d1 d2 d12 old
  d1="$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%SZ)"; d2="$(date -u -d '-4 days' +%Y-%m-%dT%H:%M:%SZ)"
  d12="$(date -u -d '-12 days' +%Y-%m-%dT%H:%M:%SZ)"; old="2026-01-01T00:00:00Z"
  run env _RUNS_CACHE_DIR="$_RUNS_CACHE_DIR" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e
    for s in '$d1' '$d2' '$d12' '$old'; do _agent_run_json dev-lead org/busy \"\$s\" >/dev/null 2>&1; done
    for s in '$d1' '$d2' '$d12' '$old'; do _agent_run_json dev-lead org/busy \"\$s\" >/dev/null 2>&1; done"
  [ "$status" -eq 0 ]
  # tiers: 8d (shared by d1 and d2), 15d (d12), unbounded (old) = 3 distinct ingress fetches, each once.
  [ "$(grep -c -- '--workflow Agent Ingress' "$GH_LOG")" -eq 3 ]
}

@test "_agent_run_json: a date-bounded ingress list that hits the cap is judged exactly like an unbounded one (#1259)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # org/busy lists 3 runs (today x2, yesterday). Cap = 3 and a window that starts 3 days ago: the oldest
  # listed run (yesterday) is NOT before the window start, so older in-window runs may be missing.
  local since; since="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
  run env CANARY_INGRESS_RUN_LIMIT=3 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '$since' 2>/dev/null"
  [ "$status" -eq 0 ]
  grep -q -- "--created" "$GH_LOG"
  grep -q "CANARY_INGRESS_RUN_LIMIT" "$flag"
}

# A gh wrapper for the 1,000-result cap on date-filtered run listings: a bounded (--created) listing of
# org/busy returns exactly 1000 runs whose oldest is <oldest_days> days old; everything else is the normal stub.
_bounded_cap_stub() {
  local oldest_days="$1"
  mv "$STUB_BIN/gh" "$STUB_BIN/gh.real"
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case " \$* " in
  *" --repo org/busy "*"--workflow Agent Ingress"*"--created"*)
    echo "\$*" >> "\$GH_LOG"
    jq -nc --argjson days $oldest_days '[range(0;1000) | {conclusion:"success", databaseId:(5000+.), workflowName:"Agent Ingress",
      createdAt:((now - (\$days*86400) + (.*60)) | strftime("%Y-%m-%dT%H:%M:%SZ"))}]'
    exit 0 ;;
esac
exec "$STUB_BIN/gh.real" "\$@"
GHEOF
  chmod +x "$STUB_BIN/gh"
}

@test "_agent_run_json: a date-bounded ingress list that reaches GitHub's 1000-result search cap without reaching the window start falls back to the unbounded list (#1262 review)" {
  _ingress_stub
  _bounded_cap_stub 1      # 1000 runs spanning the last ~16h: does NOT reach back past a 3-day-old window start
  local since; since="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '$since' 2>/dev/null | jq -c 'map(.databaseId)|sort'"
  [ "$status" -eq 0 ]
  # the result comes from the unbounded (normal stub) list of 3 runs, not from the 1000 junk runs
  [ "$output" = "[301,302,303]" ]
  [ "$(grep -c -- '--workflow Agent Ingress' "$GH_LOG")" -eq 2 ]
  grep -- '--workflow Agent Ingress' "$GH_LOG" | sed -n 1p | grep -q -- '--created'
  run bash -c "grep -- '--workflow Agent Ingress' '$GH_LOG' | sed -n 2p"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--workflow Agent Ingress"* ]]
  [[ "$output" != *"--created"* ]]
}

@test "_agent_run_json: a date-bounded ingress list at the cap that DOES reach back before the window start is trusted — no second fetch (#1262 review)" {
  _ingress_stub
  _bounded_cap_stub 5      # 1000 runs reaching back ~5 days: covers a window that started 3 days ago
  local since; since="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
  run env CANARY_INGRESS_JOBS_MAX=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$BATS_TEST_TMPDIR/flag" \
    bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/busy '$since' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--workflow Agent Ingress' "$GH_LOG")" -eq 1 ]
  grep -- '--workflow Agent Ingress' "$GH_LOG" | grep -q -- '--created'
}

@test "_timing_kind: gh run list is labelled with its workflow, cap and whether it was date-bounded (#1259)" {
  run bash -c "source '$ORCH'
    k() { _timing_kind \"\$@\"; echo \"\$_TIMING_KIND\"; }
    k run list --repo o/r --workflow 'Agent Ingress' -L 5000 --created '>=2026-01-01' --json x
    k run list --repo o/r --workflow 'Agent Ingress' -L 5000 --json x
    k run list --repo o/r --workflow 'Dev-Lead Agent' -L 1000 --json x
    k run view 12"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "run list [Agent Ingress] L=5000 bounded" ]
  [ "${lines[1]}" = "run list [Agent Ingress] L=5000" ]
  [ "${lines[2]}" = "run list [Dev-Lead Agent] L=1000" ]
  [ "${lines[3]}" = "run view" ]
}

@test "_timing_kind: gh api calls group by endpoint, not by repo/tag/id (#1259)" {
  run bash -c "source '$ORCH'
    k() { _timing_kind \"\$@\"; echo \"\$_TIMING_KIND\"; }
    k run list -R o/r
    k api repos/o/a/git/ref/tags/v1
    k api -H 'Accept: x' repos/o/b/git/ref/tags/v2?per_page=1
    k api --jq .x /repos/o/c/actions/runs/9
    k api repos/o/d/commits/abc123
    k api repos/o/e/commits/def456
    k api repos/o/f/contents/a/b/c.txt
    k api repos/o/g
    k api /installation/repositories"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "run list [?] L=default" ]
  [ "${lines[1]}" = "api repos/git/ref" ]
  [ "${lines[2]}" = "api repos/git/ref" ]
  [ "${lines[3]}" = "api repos/actions/runs" ]
  [ "${lines[4]}" = "api repos/commits" ]             # an id in the 5th segment is dropped, not kept per call
  [ "${lines[5]}" = "api repos/commits" ]
  [ "${lines[6]}" = "api repos/contents" ]
  [ "${lines[7]}" = "api repos/" ]
  [ "${lines[8]}" = "api installation/" ]
}

@test "main: the timing report runs for a caller-supplied cache dir, which is not removed (#1259)" {
  _ingress_stub
  local d="$BATS_TEST_TMPDIR/callerdir"; mkdir -p "$d"
  run env CANARY_TIMING=1 _RUNS_CACHE_DIR="$d" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH'; cmd_drift() { gh run list -R org/a >/dev/null 2>&1; }; main drift 2>&1"
  [ -d "$d" ]
  [[ "$output" == *"canary timing [drift]:"* ]]
  [ -z "$(ls -A "$d")" ]                               # per-process timing files are removed at exit
}

@test "_agent_run_json: the jobs-read circuit breaker stops after the first exhausted 5xx instead of retrying every run (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env STUB_JOBS_FAIL=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _agent_run_json dev-lead org/collapsed '' 2>/dev/null"
  [ "$status" -eq 0 ]
  # org/collapsed has three completed runs (104, 102, 101); without the breaker all three are read.
  [ "$(grep -c '^run view ' "$GH_LOG")" -eq 1 ]
  grep -q "jobs endpoint unreadable" "$flag"
}

@test "_agent_run_json: an ingress run from BEFORE the role was added to the ingress is not-yet-adopted, not UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # 410 (older) has only pr-review's job; 411 (newer) carries dev-lead's. The role's oldest appearance is
  # 411, so 410 predates adoption and must not hold a correctly configured member BLOCKED for ~14 days.
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/preadopt '' 2>/dev/null | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]
  [ "$output" = '[411]' ]
  [ ! -s "$flag" ]
}

@test "_agent_run_json: a no-role ingress run NEWER than the role's first appearance is still UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/rolegap '' 2>/dev/null | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]
  [ "$output" = '[421]' ]
  grep -q "carry no 'dev-lead' job" "$flag"
}

@test "_agent_run_json: when NO run carries the role (ingress_job renamed/misspelled) the member is UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/norole '' 2>/dev/null | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  grep -q "carry no 'dev-lead' job" "$flag"
}

@test "_agent_run_json: a failed job plus an action_required job of the same role stays a FAILURE in either order (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # jq max_by keeps the last of tied elements; with failure and action_required ranked equal, the role's
  # conclusion depended on job order and a real failure could be dropped from cum_fail.
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/tie '' 2>/dev/null | jq -c 'map(.conclusion)'"
  [ "$status" -eq 0 ]
  [ "$output" = '["failure","failure"]' ]
  [ ! -s "$flag" ]
}

@test "_agent_run_json: a job-less startup_failure is not the role's first appearance — an older no-role run stays UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  # 461 (newer) has no jobs at all (startup_failure, so it counts as a failure); 462 (older) has only another
  # role's job. No run carries dev-lead's job, so 462 is blind (misspelled ingress_job?), not pre-adoption.
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/sfgap '' 2>/dev/null | jq -c 'map([.databaseId,.conclusion])'"
  [ "$status" -eq 0 ]
  [ "$output" = '[[461,"startup_failure"]]' ]
  grep -q "carry no 'dev-lead' job" "$flag"
}

@test "_run_signature and _run_decision_class make ONE gh call on a failing lookup, not the ingress retry loop (#1224 regression)" {
  _ingress_stub
  # Before #1224 these legacy single-call readers did one `gh run view` and failed fast. A persistently
  # failing lookup (410 expired logs, 403/rate limit) must not cost the 6-attempt backoff per run.
  run env STUB_JOBS_FAIL=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=6 \
    bash -c "source '$ORCH'; set +e; _run_signature org/collapsed 101 '' >/dev/null 2>&1; _run_decision_class org/collapsed 102 dev-lead '' >/dev/null 2>&1; true"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^run view ' "$GH_LOG")" -eq 2 ]
}

@test "_run_jobs_json: the ingress path keeps the bounded retry (CANARY_GH_RETRIES attempts) on a transient 5xx (#1224)" {
  _ingress_stub
  run env STUB_JOBS_FAIL=1 CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=3 \
    bash -c "source '$ORCH'; set +e; _run_jobs_json org/collapsed 101 >/dev/null 2>&1; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
  [ "$(grep -c '^run view ' "$GH_LOG")" -eq 3 ]
}

@test "_agent_run_json: a job-less CANCELLED ingress run never executed the role — no record, not UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "set -o pipefail; source '$ORCH' && _agent_run_json dev-lead org/cancelled '' 2>/dev/null | jq -c 'map(.databaseId)'"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [ ! -s "$flag" ]
}

@test "_agent_run_json: an ingress run with NO jobs cannot be attributed → member reported UNRESOLVED (#1224)" {
  _ingress_stub
  local flag="$BATS_TEST_TMPDIR/unresolved"; : > "$flag"
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 _CANARY_UNRESOLVED_FLAG="$flag" \
    bash -c "source '$ORCH' && _agent_run_json dev-lead org/nojobs ''"
  [ "$status" -eq 0 ]
  grep -q "^org/nojobs" "$flag"
}

@test "_cumulative_health: an ingress role's failure counts, another role's failure in the same run does not leak in (#1224)" {
  _ingress_stub
  # differs=0 activates dev-lead's [Pp]ush benign class. Run 102's dev-lead job failed at
  # 'Build'; only pr-review's job failed at 'Push'. A run-wide signature would wrongly see
  # 'Push' and excuse dev-lead's failure as benign — the role-scoped signature must not.
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH' && _cumulative_health dev-lead '' 0 - org/collapsed"
  [ "$status" -eq 0 ]
  [ "$output" = "1 0 0 0 0" ]
}

@test "_tier_sample: a MIXED ring (collapsed + legacy member) counts both in one evaluation (#1224)" {
  _ingress_stub
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH' && _tier_sample dev-lead '' org/collapsed org/legacy"
  [ "$status" -eq 0 ]
  # collapsed: 101 + 102 executed; legacy: 201.
  [ "$output" = "3 2026-01-02T00:00:00Z" ]
}

# _frontier_state with tag resolution stubbed out (candidate on next only; cut before the runs).
_ingress_frontier() {
  local agent="$1"
  env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'
    channel_commit() { case \"\$2\" in next) echo cand ;; *) echo prior ;; esac; }
    candidate_cut_date() { echo 2026-01-01T00:00:00Z; }
    _reusable_differs() { echo 0; }
    _frontier_state $agent"
}

@test "_frontier_state: an uncreatable unresolved flag fails closed as FLAG_ERROR with a full 18-field line (#1224)" {
  _ingress_stub
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'
    channel_commit() { case \"\$2\" in next) echo cand ;; *) echo prior ;; esac; }
    candidate_cut_date() { echo 2026-01-01T00:00:00Z; }
    _reusable_differs() { echo 0; }
    _unresolved_flag_path() { echo '$BATS_TEST_TMPDIR/no-such-dir/flag'; }   # cannot be created
    _frontier_state cfa 2>/dev/null"
  [ "$status" -eq 0 ]
  local line; line="$(grep ' FLAG_ERROR ' <<< "$output" | head -1)"
  [ -n "$line" ]
  [[ "$line" == *" BLOCKED "* ]]
  # cmd_sync_issues appends the datagap field, so a short line would shift it into `downgrade`.
  [ "$(wc -w <<< "$line")" -eq 18 ]
}

@test "_frontier_state: a MIXED ring that fully resolves gates normally (collapsed + legacy → PROMOTE) (#1224)" {
  _ingress_stub
  run _ingress_frontier cfa
  [ "$status" -eq 0 ]
  read -r _c frontier transition state _rest <<< "$(printf '%s\n' "$output" | tail -1)"
  [ "$frontier" = "ring0" ]; [ "$state" = "PROMOTE" ]
  [[ "$output" != *"UNRESOLVED"* ]]
}

@test "_frontier_state: an UNRESOLVED member fails the gate loudly — BLOCKED/UNRESOLVED, never PROMOTE (#1224)" {
  _ingress_stub
  run _ingress_frontier noingress
  [ "$status" -eq 0 ]
  # The member is named in an ::error:: annotation…
  [[ "$output" == *"::error::"*"org/collapsed"* ]]
  # …and the state line holds the promotion with triage UNRESOLVED.
  local line; line="$(printf '%s\n' "$output" | tail -1)"
  read -r _c frontier transition state _d _f _s _t _cf _cs _cb triage _rest <<< "$line"
  [ "$state" = "BLOCKED" ]
  [ "$triage" = "UNRESOLVED" ]
}

@test "_blocker_body: UNRESOLVED triage explains the blind member, not a cut-date indeterminate (#1224)" {
  run bash -c "source '$ORCH' && _blocker_body dev-lead 'next->ring0' cand 0 0 UNRESOLVED petry-projects/.github-private '- \`org/collapsed\` — ingress present'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNRESOLVED"* ]]
  [[ "$output" == *"ingress_job"* ]]
  [[ "$output" != *"cut date unresolved"* ]]
}

@test "registry: every ADR-0007-collapsed role carries ingress_job = its ingress job key, documented (#1224)" {
  [ "$(jq -r '.ingress.workflow' "$RINGS")" = "Agent Ingress" ]
  [ -n "$(jq -r '._ingress_note // empty' "$RINGS")" ]
  local a
  for a in dev-lead pr-review-mention pr-auto-review pr-review ci-failure-analyst; do
    [ "$(jq -r --arg a "$a" '.agents[$a].ingress_job // empty' "$RINGS")" = "$a" ]
  done
}

@test "_unresolved_evidence: the blocker issue names each blind member and why (#1224)" {
  _ingress_stub
  run env CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'
    candidate_cut_date() { echo 2026-01-01T00:00:00Z; }
    _unresolved_evidence noingress cand"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`org/collapsed`'*"ingress_job"* ]]
  # The resolvable legacy member is not listed.
  [[ "$output" != *"org/legacy"* ]]
}

@test "_record_unresolved: a failed evidence append removes the flag so the gate cannot read it as clean (#1224)" {
  # Force the append to fail via a printf shim, not file modes (a root runner bypasses chmod 444).
  local flag="$BATS_TEST_TMPDIR/unresolved-ro"; : > "$flag"
  run env _CANARY_UNRESOLVED_FLAG="$flag" ORCH="$ORCH" bash -c 'source "$ORCH" && printf() { if [ "$1" = "%s\n" ]; then return 1; fi; builtin printf "$@"; } && _record_unresolved dev-lead org/x blind 2>/dev/null'
  [ ! -e "$flag" ]
}

@test "canary-rollout.yml: the sweep shares one run-list cache dir across its steps (#1259)" {
  # Line numbers of each step's `- name:` (no YAML parser: the test job installs only bats/shellcheck/jq).
  _ln() { grep -n -m1 -- "- name: $1" "$WORKFLOW" | cut -d: -f1; }
  local share autocut run drop sync
  share="$(_ln 'Share run-list cache')"; autocut="$(_ln 'Autocut')"; run="$(_ln 'Run canary-rollout')"
  drop="$(_ln 'Drop cached lookup failures')"; sync="$(_ln 'Sync blocker issues')"
  [ -n "$share" ] && [ -n "$autocut" ] && [ -n "$run" ] && [ -n "$drop" ] && [ -n "$sync" ]
  [ "$share" -lt "$autocut" ]; [ "$autocut" -lt "$run" ]
  [ "$run" -lt "$drop" ]; [ "$drop" -lt "$sync" ]
  # The share step exports the dir through GITHUB_ENV; the cleanup step drops only empty sha_* entries.
  sed -n "${share},$((autocut - 1))p" "$WORKFLOW" | grep -q '_RUNS_CACHE_DIR=.*GITHUB_ENV'
  sed -n "${drop},$((sync - 1))p" "$WORKFLOW" | grep -q -- "-name 'sha_\*' -size 0"
}

@test "cross-process: a second process sharing _RUNS_CACHE_DIR makes no run-list calls (#1259)" {
  _ingress_stub
  local d="$BATS_TEST_TMPDIR/shared"; mkdir -p "$d"
  local snippet="source '$ORCH'; set +e; _agent_run_json dev-lead org/collapsed '' >/dev/null 2>&1"
  env _RUNS_CACHE_DIR="$d" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "$snippet"
  [ "$(grep -c '^run list ' "$GH_LOG")" -ge 1 ]
  : > "$GH_LOG"
  env _RUNS_CACHE_DIR="$d" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "$snippet"
  [ "$(grep -c '^run list ' "$GH_LOG")" -eq 0 ]
}

@test "main: a caller-supplied cache dir keeps its cache files at exit (#1259)" {
  _ingress_stub
  local d="$BATS_TEST_TMPDIR/keepdir"; mkdir -p "$d"
  run env _RUNS_CACHE_DIR="$d" CANARY_RINGS="$INGRESS_RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 \
    bash -c "source '$ORCH'; cmd_drift() { _agent_run_json dev-lead org/collapsed '' >/dev/null 2>&1; }; main drift 2>&1"
  [ "$status" -eq 0 ]
  [ -n "$(ls -A "$d")" ]
}

# ── #1246 item 10: static lint of the registry's `ingress_job` values ────────────────────────────────────
# A runtime check cannot fail on "role absent from this member's ingress" — that is also what a legitimate
# non-consumer looks like — so with an empty ingress window a misspelled `ingress_job` read as "no caller" and
# `waive_sample_if_no_caller` could allow a dwell-only promotion. The typo is caught here instead, before it ships:
# every registered `ingress_job` must be a job key of the canonical `agent-ingress.yml` template. Runtime keeps
# treating an empty window as "no caller" (expected, not a failure).
INGRESS_TEMPLATE="${CANARY_INGRESS_TEMPLATE:-$SCRIPT_DIR/standards/workflows/agent-ingress.yml}"

# _ingress_registry_lint <registry.json> <template.yml> — prints one line per registered ingress_job the template
# does NOT declare ("<agent>: <job>"); exit 1 if any, 0 if none.
_ingress_registry_lint() {
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/scripts/lib/agent-ingress.sh"
  local agent job bad=0
  while IFS=$'\t' read -r agent job; do
    agent_ingress_has_role_job "$job" < "$2" || { printf '%s: %s\n' "$agent" "$job"; bad=1; }
  done < <(jq -r '.agents | to_entries[] | select(.value.ingress_job) | [.key, .value.ingress_job] | @tsv' "$1")
  return "$bad"
}

@test "registry lint: every ingress_job is a plain job key and unique across agents (#1246 item 10)" {
  run jq -r '[.agents[] | .ingress_job // empty] | (map(select(test("^[a-z0-9][a-z0-9-]*$") | not)) | join(",")) as $bad
             | (group_by(.) | map(select(length > 1) | .[0]) | join(",")) as $dup
             | "bad=[\($bad)] dup=[\($dup)]"' "$RINGS"
  [ "$status" -eq 0 ]
  [ "$output" = "bad=[] dup=[]" ]
}

@test "registry lint: every registered ingress_job is a job of the canonical agent-ingress.yml template (#1246 item 10)" {
  if [ ! -f "$INGRESS_TEMPLATE" ]; then
    skip "canonical template not published yet ($INGRESS_TEMPLATE; petry-projects/.github-private#1729 AC11(a)) — lint is dormant until it lands"
  fi
  run _ingress_registry_lint "$RINGS" "$INGRESS_TEMPLATE"
  [ "$status" -eq 0 ] || { echo "ingress_job not declared by the canonical ingress:"; echo "$output"; return 1; }
}

@test "registry lint: a registered ingress_job the template lacks is reported by agent and job (#1246 item 10)" {
  local tpl="$BATS_TEST_TMPDIR/ingress.yml" reg="$BATS_TEST_TMPDIR/reg.json"
  cat > "$tpl" <<'YML'
name: Agent Ingress
jobs:
  dev-lead:
    uses: x/y/.github/workflows/dev-lead-reusable.yml@v1
  "pr-review":
    uses: x/y/.github/workflows/pr-review.yml@v1
  pr-review-mention-ci:
    uses: x/y/.github/workflows/z.yml@v1
YML
  jq -n '{agents:{
    "dev-lead":{ingress_job:"dev-lead"},
    "pr-review":{ingress_job:"pr-review"},
    "pr-review-mention":{ingress_job:"pr-review-mention"},
    "typo-agent":{ingress_job:"dev-leed"},
    "legacy":{}}}' > "$reg"
  run _ingress_registry_lint "$reg" "$tpl"
  [ "$status" -eq 1 ]
  # a role-name PREFIX (`pr-review-mention-ci:`) does not satisfy `pr-review-mention`; an agent without ingress_job is ignored
  [ "$output" = "$(printf 'pr-review-mention: pr-review-mention\ntypo-agent: dev-leed')" ]
  # and a template declaring all of them is clean
  printf '  pr-review-mention:\n    uses: x\n  dev-leed:\n    uses: x\n' >> "$tpl"
  run _ingress_registry_lint "$reg" "$tpl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── #1259 option B: the per-role (legacy) run list is date-bounded to one 15-day tier ─────────────────────
# The gate only samples windows that start at most ~2 weeks back, so the newest 1000 runs of a busy workflow were
# mostly dead weight (promote-all spent ~750 s of 925 s on `run list -L 1000`). The stub honors `--created` the
# way GitHub does (newest-first, createdAt date >= bound), so bounded and unbounded reads can be compared.
_legacy_runs_stub() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  export GH_LOG="$BATS_TEST_TMPDIR/gh-legacy.log"; : > "$GH_LOG"
  export FIXTURE="$BATS_TEST_TMPDIR/legacy-runs.json"
  local d2 d9 d14 d20
  d2="$(date -u -d '-2 days' +%Y-%m-%dT10:00:00Z)"; d9="$(date -u -d '-9 days' +%Y-%m-%dT10:00:00Z)"
  d14="$(date -u -d '-14 days' +%Y-%m-%dT10:00:00Z)"; d20="$(date -u -d '-20 days' +%Y-%m-%dT10:00:00Z)"
  jq -n --arg a "$d2" --arg b "$d9" --arg c "$d14" --arg d "$d20" '[
    {conclusion:"success",createdAt:$a,databaseId:1,workflowName:"Dev-Lead Agent"},
    {conclusion:"failure",createdAt:$b,databaseId:2,workflowName:"Dev-Lead Agent"},
    {conclusion:"success",createdAt:$c,databaseId:3,workflowName:"Dev-Lead Agent"},
    {conclusion:"failure",createdAt:$d,databaseId:4,workflowName:"Dev-Lead Agent"}]' > "$FIXTURE"
  cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
created=""; prev=""
for a in "$@"; do [ "$prev" = "--created" ] && created="${a#>=}"; prev="$a"; done
case "$1 $2" in
  "run list") jq -c --arg c "$created" '[.[] | select($c == "" or (.createdAt[0:10] >= $c))]' "$FIXTURE" ;;
  *) echo '{}' ;;
esac
GHEOF
  chmod +x "$STUB_BIN/gh"
}
_ago() { date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ; }

@test "_agent_run_json: the per-role run list is fetched date-bounded to the 15-day tier for a recent window (#1259 option B)" {
  _legacy_runs_stub
  run env CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '$(_ago 5)' | jq -r '[.[].databaseId] | join(\",\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  grep -q -- "--created >=$(date -u -d '-15 days' +%Y-%m-%d)" "$GH_LOG"
  grep -q -- "-L 1000" "$GH_LOG"
}

@test "_agent_run_json: a window older than the tier, or an empty window, reads the unbounded list as before (#1259 option B)" {
  _legacy_runs_stub
  run env CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '$(_ago 21)' | jq -r '[.[].databaseId] | join(\",\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "1,2,3,4" ]
  run grep -q -- "--created" "$GH_LOG"
  [ "$status" -eq 1 ]
  : > "$GH_LOG"
  run env CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '' | jq -r '[.[].databaseId] | join(\",\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "1,2,3,4" ]
  run grep -q -- "--created" "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "_agent_run_json: CANARY_RUNS_HORIZON_TIERS='' disables the per-role bound (#1259 option B)" {
  _legacy_runs_stub
  run env CANARY_RUNS_HORIZON_TIERS='' CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '$(_ago 5)' | jq -r '[.[].databaseId] | join(\",\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -q -- "--created" "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "_agent_run_json: bounded and unbounded reads give the same runs for every window within the tier (#1259 option B)" {
  _legacy_runs_stub
  local days out_b out_u
  for days in 1 3 5 10 13 14; do
    out_b="$(env CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '$(_ago $days)'")"
    out_u="$(env CANARY_RUNS_HORIZON_TIERS='' CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '$(_ago $days)'")"
    [ -n "$out_b" ]
    [ "$out_b" = "$out_u" ] || { echo "window=$days bounded=$out_b unbounded=$out_u"; return 1; }
  done
}

@test "_agent_run_json: windows of different ages share ONE per-role fetch, and a capped bounded list triggers no refetch (#1259 option B)" {
  _legacy_runs_stub
  local cache="$BATS_TEST_TMPDIR/rc-legacy" recent; mkdir -p "$cache"
  run env _RUNS_CACHE_DIR="$cache" CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e
    for d in 2 7 11 14; do _agent_run_json dev-lead org/legacy \"\$(date -u -d \"-\$d days\" +%Y-%m-%dT%H:%M:%SZ)\" >/dev/null; done"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^run list ' "$GH_LOG")" -eq 1 ]
  # A bounded list that fills the 1000 cap IS the newest-1000 (newest-first), so it is used as is: no second read.
  : > "$GH_LOG"; cache="$BATS_TEST_TMPDIR/rc-legacy-cap"; mkdir -p "$cache"
  # Dated relative to now: a fixed date would fall behind the stub's 15-day bound and filter every row out.
  recent="$(date -u -d '-1 days' +%Y-%m-%dT10:00:00Z)"
  jq -n -c --arg c "$recent" '[range(1000) as $i | {conclusion:"success",createdAt:$c,databaseId:$i,workflowName:"Dev-Lead Agent"}]' > "$FIXTURE"
  run env _RUNS_CACHE_DIR="$cache" CANARY_RINGS="$RINGS" CANARY_GH_RETRY_SLEEP=0 CANARY_GH_RETRIES=1 bash -c "
    source '$ORCH'; set +e; _agent_run_json dev-lead org/legacy '$(_ago 5)' | jq 'length'"
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ]
  [ "$(grep -c '^run list ' "$GH_LOG")" -eq 1 ]
}
