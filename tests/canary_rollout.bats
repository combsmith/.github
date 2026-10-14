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
# must go through `gh api` on the host. agent-shield (host = combsmith/.github) is the
# cross-repo agent here, with THIS_REPO forced to .github-private via GITHUB_REPOSITORY.
@test "_reusable_differs: cross-repo agent resolves host blobs via gh api — differ → 1" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  { echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    echo '  *"ref=CAND"*)  echo "aaaaaaaaaa" ;;'
    echo '  *"ref=PRIOR"*) echo "bbbbbbbbbb" ;;'
    echo '  *) echo "" ;;'
    echo 'esac'; } > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env GITHUB_REPOSITORY="combsmith/.github-private" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _reusable_differs agent-shield CAND PRIOR"
  [ "$status" -eq 0 ]; [ "$output" = "1" ]
}

@test "_reusable_differs: cross-repo agent — identical host blob → 0" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho "samesamesame"\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env GITHUB_REPOSITORY="combsmith/.github-private" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _reusable_differs agent-shield CAND PRIOR"
  [ "$status" -eq 0 ]; [ "$output" = "0" ]
}

@test "_reusable_differs: cross-repo agent — unresolvable blob fails CLOSED → 1" {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  printf '#!/usr/bin/env bash\necho ""\n' > "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  run env GITHUB_REPOSITORY="combsmith/.github-private" CANARY_RINGS="$RINGS" \
    bash -c "source '$ORCH' && _reusable_differs agent-shield CAND PRIOR"
  [ "$status" -eq 0 ]; [ "$output" = "1" ]
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

# ── canary-rings.json SoT shape (rings + gate knobs) ──────────────────────────
@test "canary-rings.json: pr-auto-review onboarded to canary; unmanaged block emptied" {
  run jq -e '.agents["pr-auto-review"].host == "combsmith/.github"' "$RINGS"
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
  run jq -e '.agents["add-to-project"].host == "combsmith/.github"' "$RINGS"
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
  run jq -e '.agents["feature-ideation"].host == "combsmith/.github"' "$RINGS"
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
  run jq -e '.agents["ci-failure-analyst"].host == "combsmith/.github-private"' "$RINGS"
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

@test "canary-rings.json: valid JSON + dev-lead host + ordered rings" {
  run jq -e '.agents["dev-lead"].host == "combsmith/.github-private"' "$RINGS"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.agents[\"dev-lead\"].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
  [ "$output" = "next,ring0,ring1,stable" ]
  run jq -e '.agents["dev-lead"].rings[] | select(.channel=="ring1") | (.members | index("combsmith/TalkTerm")) and (.members | index("combsmith/bmad-bgreat-suite"))' "$RINGS"
  [ "$status" -eq 0 ]
}

@test "canary-rings.json: idea->initiative pipeline agents onboarded (standard rings + gate, #1008)" {
  # initiative-planner + idea-triage are host=.github agents with sparse, event-driven
  # traffic. They ride the STANDARD ring model + gate — NO synthetic canary: the empty
  # inner rings waive on dwell (no caller), and ring1->stable soaks until real
  # TalkTerm/bmad traffic (organic or human-triggered) arrives.
  local a
  for a in initiative-planner idea-triage idea-enhancer; do
    run jq -e --arg a "$a" '.agents[$a].host == "combsmith/.github"' "$RINGS"
    [ "$status" -eq 0 ]
    run bash -c "jq -r --arg a '$a' '.agents[\$a].rings | sort_by(.order) | map(.channel) | join(\",\")' '$RINGS'"
    [ "$output" = "next,ring0,ring1,stable" ]
    # ring1 = the real consumers that gate ring1->stable
    run jq -e --arg a "$a" '.agents[$a].rings[] | select(.channel=="ring1") | (.members|index("combsmith/TalkTerm")) and (.members|index("combsmith/bmad-bgreat-suite"))' "$RINGS"
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
  [ "$status" -eq 0 ]; [ "$output" = "combsmith/.github-private" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring0"
  [ "$status" -eq 0 ]; [ "$output" = "combsmith/.github" ]
  run bash -c "source '$ORCH' && CANARY_RINGS='$RINGS' resolve_members dev-lead ring1"
  [[ "$output" == *"combsmith/TalkTerm"* ]]
  [[ "$output" == *"combsmith/bmad-bgreat-suite"* ]]
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
# (#1049) A cross-repo agent (host = combsmith/.github) keeps its <name>/<channel>
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
  # checkout. The for-each-ref simulates a lightweight release tag at the candidate commit.
  cat > "$STUB_BIN/git" <<GITEOF
#!/usr/bin/env bash
case "\$*" in
  *"for-each-ref"*) printf '%s||%s\n' "$cand" "$cut_iso" ;;
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
# A cross-repo agent (host = combsmith/.github) keeps its channel tags on the host, so
# the promote move must go through `gh api PATCH .../git/refs/tags/...`, NOT local `git tag -f`
# (which fails "nonexistent object" for a host commit absent from this checkout — #1054).
@test "orchestrator: cross-repo promote --dry-run shows the host gh-api move, not a local git tag (#1054)" {
  _crossrepo_stub 2 1 success   # auto-rebase ring1->stable PROMOTE
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote auto-rebase --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"gh api PATCH repos/combsmith/.github/git/refs/tags/auto-rebase/stable"* ]]
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
  *"for-each-ref"*) printf '%s||%s\n' "$cand" "$cut_iso" ;;
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
  grep -q "PATCH repos/combsmith/.github/git/refs/tags/auto-rebase/stable" "$MOVE_LOG"
  ! grep -q "^LOCAL:" "$MOVE_LOG"
  # The move is exposed for the workflow's GitHub Deployment step (#502).
  grep -q "promoted_agent=auto-rebase" "$out"
  grep -q "promoted_ring=stable" "$out"
  # promoted_host is the OWNING repo (the cross-repo host), so the deployment is created
  # where the moved commit exists — not GITHUB_REPOSITORY, which would 422 "No ref found" (#1059).
  grep -q "promoted_host=combsmith/.github" "$out"
  # The promotions log gets one TSV line per move (agent, ring, sha, owning-repo) so a
  # promote-all run can record a deployment for EVERY promotion, not just the last.
  grep -qP "^auto-rebase\tstable\t[0-9a-f]+\tcombsmith/\.github$" "$plog"
}

@test "orchestrator: cross-repo promote --dry-run shows the host move but touches neither git nor the API (#1054)" {
  _crossrepo_promote_stub 2 1 success
  run env CANARY_RINGS="$RINGS" bash "$ORCH" promote auto-rebase --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"auto-rebase/stable"* ]]
  [[ "$output" == *"combsmith/.github"* ]]
  [ ! -f "$MOVE_LOG" ]
}

# ── orchestrator: sync-issues — auto-triage held promotions into tracked issues ──
# A held (BLOCKED) promotion files/updates ONE idempotent issue per agent with the failing-run
# evidence; a cleared agent's issue auto-closes; the fleet-status table is rendered to the job
# summary. dev-lead-only registry keeps the fleet loop to one agent; the gh stub logs issue ops.
_sync_stub() {
  # $1 conclusion (failure→BLOCKED | success→cleared); $2 blocker-list JSON returned by `gh issue list`
  # dev-lead is cross-repo (host=.github-private, THIS_REPO=.github): channel tags, release
  # date, and reusable blobs resolve via gh api; git is a no-op.
  local concl="$1" blocker_list="${2:-[]}"
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
  *"git/ref/tags/dev-lead/next"*)   echo "cccccccccccccccccccccccccccccccccccccccc commit" ;;
  *"git/ref/tags/dev-lead/ring0"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/ring1"*)  echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"git/ref/tags/dev-lead/stable"*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit" ;;
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
  *"git/tags/tagobj"*) printf '%s\t%s\n' "cccccccccccccccccccccccccccccccccccccccc" "$cut_iso" ;;
  *"ref=cccc"*) echo "blobAAAA" ;;
  *"ref=bbbb"*) echo "blobAAAA" ;;
  *"run list"*) jq -nc --arg d "$run_iso" --arg c "$concl" '[range(3)|{conclusion:\$c,createdAt:\$d,databaseId:12345,workflowName:"Dev-Lead Agent"}]' ;;
  *"run view"*) echo '{"jobs":[{"steps":[{"name":"Some step","conclusion":"failure"}]}]}' ;;
  "issue list"*) echo '$blocker_list' ;;
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/combsmith/.github-private/issues/777" ;;
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
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would OPEN blocker issue for dev-lead"* ]]
  grep -q "Canary Rollout — fleet status" "$summ"   # table still renders under --dry-run
  [ ! -s "$ISSUE_LOG" ]   # dry-run mutates nothing on GitHub
}

@test "orchestrator: sync-issues opens ONE blocker issue (with evidence) + writes the fleet summary — no dashboard issue" {
  _sync_stub failure '[]'
  local summ="$BATS_TEST_TMPDIR/summary.md"; : > "$summ"
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
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
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not open blocker issue for dev-lead (Issues:write on the App?)"* ]]
  [[ "$output" == *"wrote fleet-status table to the job summary"* ]]
  grep -q "Canary Rollout — fleet status" "$summ"
  grep -q "dev-lead" "$summ"
}

@test "orchestrator: sync-issues auto-closes a cleared agent's open blocker issue" {
  # dev-lead now clean (success → not BLOCKED) but an OPEN blocker issue #501 exists → close it.
  _sync_stub success '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
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
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  # The header must appear at the start of a line — not concatenated onto the prior content.
  grep -q '^# Canary Rollout' "$summ"
  ! grep -q 'prior.*# Canary Rollout' "$summ"
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
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
  [ ! -s "$GH_LOG" ]   # nothing cut when the kill-switch is off
}

@test "orchestrator: autocut cuts a patch-bumped version + moves next when the reusable blob differs on main" {
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # Highest existing tag is v2.1.0 → patch bump → v2.1.1, annotated tag cut from main HEAD on the
  # HOST repo (.github-private for dev-lead), then `next` force-moved onto the same commit — all gh-api.
  grep -q "repos/combsmith/.github-private/git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/combsmith/.github-private/git/refs/tags/dev-lead/next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut is idempotent — identical blob on main and next is a clean no-op" {
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    sameBLOB sameBLOB aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cut"* ]]
  [ ! -s "$GH_LOG" ]   # nothing cut when the blob is unchanged
}

@test "orchestrator: autocut --dry-run prints the intended cut without writing any tag" {
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"2.1.1"* ]]
  [ ! -s "$GH_LOG" ]   # dry-run never writes a real cut
}

@test "orchestrator: autocut honors the registry autocut.bump override (minor)" {
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" minor
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # minor bump of v2.1.0 → v2.2.0
  grep -q "repos/combsmith/.github-private/git/tags .*tag=dev-lead/v2.2.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
}

@test "orchestrator: autocut is cross-repo aware — cuts v2.1.1 for auto-rebase on the host repo (#1069)" {
  # auto-rebase is hosted in combsmith/.github; its next candidate + release tags live there,
  # so the next commit is resolved via gh api (not local git) and BOTH the tag create and the
  # next move are written to that host — not GITHUB_REPOSITORY.
  _autocut_stub auto-rebase combsmith/.github .github/workflows/auto-rebase-reusable.yml \
    ece45480ece45480ece45480ece45480ece45480 2763750027637500276375002763750027637500 \
    ece45480ece45480ece45480ece45480ece45480 2763750027637500276375002763750027637500 "2.1.0"
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "repos/combsmith/.github/git/tags .*tag=auto-rebase/v2.1.1 .*object=ece45480ece45480ece45480ece45480ece45480" "$GH_LOG"
  grep -q "PATCH repos/combsmith/.github/git/refs/tags/auto-rebase/next .*sha=ece45480ece45480ece45480ece45480ece45480" "$GH_LOG"
}

@test "orchestrator: autocut — existing release tag matching mainsha skips create and still moves next (idempotent retry)" {
  # Simulate a partial retry: the release tag was already created on a prior run (pointing to
  # mainsha), but `next` was not yet moved. The idempotency branch must skip POST git/tags
  # and proceed straight to the PATCH for next without calling _gh_create_annotated_tag.
  local mainsha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
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
  _autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
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
  # $1 = JSON array for combsmith/.github-private ; $2 = JSON array for combsmith/.github
  local priv_json="$1" pub_json="${2:-[]}"
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  # '.github' is a substring of '.github-private', so match the more specific repo FIRST.
  cat > "$STUB_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *"repos/combsmith/.github-private/contents/.github/workflows"*) cat <<'JSON'
$priv_json
JSON
    ;;
  *"repos/combsmith/.github/contents/.github/workflows"*) cat <<'JSON'
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
  [[ "$output" != *"DRIFT[unregistered] combsmith/.github-private: .github/workflows/dev-lead-reusable.yml"* ]]
  [[ "$output" != *"ci.yml present on host"* ]]
}

@test "orchestrator: drift excludes an intentionally-unmanaged reusable (#651)" {
  # Registry: dev-lead agent + an `unmanaged` entry for foo-reusable.yml on .github-private.
  DRIFT_RINGS="$BATS_TEST_TMPDIR/drift-rings-um.json"
  jq '{version, description, org_infra_repos, member_tokens,
       agents: {"dev-lead": .agents["dev-lead"]},
       unmanaged: {"foo": {"host":"combsmith/.github-private","reusable":".github/workflows/foo-reusable.yml","reason":"single-hop infra (#651)"}}}' \
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
  [[ "$output" != *"DRIFT[unregistered] combsmith/.github-private: .github/workflows/foo-reusable.yml"* ]]
  # bar (neither registered nor unmanaged) IS still flagged, and it's the ONLY one
  [[ "$output" == *"DRIFT[unregistered] combsmith/.github-private: .github/workflows/bar-reusable.yml"* ]]
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
  [[ "$output" == *"combsmith/.github-private"* ]]
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
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/combsmith/.github-private/issues/777" ;;
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
  run env CANARY_RINGS="$DG_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
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
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/combsmith/.github-private/issues/777" ;;
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
  run env CANARY_RINGS="$DG_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
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
    "source '$ORCH' && _blocker_body dev-lead 'next->ring0' cccccccccccc 1 0 SUSPECT combsmith/.github-private '_(evidence)_'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" == *"needs-human"* ]]
  [[ "$output" == *"override"* ]]   # the guidance names the fast path when unrelated
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
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/combsmith/.github-private/issues/777" ;;
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

@test "orchestrator: sync-issues CREATE path applies needs-human for SUSPECT triage" {
  # No existing issue → create path; SUSPECT (differs=1 + suspect step) must add needs-human.
  _sync_suspect_stub '[]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"opened blocker issue #777 for dev-lead"* ]]
  grep -q -- "--add-label needs-human" "$ISSUE_LOG"
}

@test "orchestrator: sync-issues UPDATE path applies needs-human for SUSPECT triage" {
  # Existing open blocker #501 → update path; SUSPECT triage must still add needs-human.
  # The create path was fixed in 4cd379b; this test pins the update-path parity contract.
  _sync_suspect_stub '[{"number":501,"state":"OPEN","body":"<!-- canary-blocker:dev-lead -->"}]'
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
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
    "source '$ORCH' && _confirm_body dev-lead 'ring1->stable' cccccccccccc bbbbbbbbbbbb combsmith/.github-private 5 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"canary-confirm:dev-lead"* ]]                              # idempotency marker
  [[ "$output" == *"compare/bbbbbbbbbbbb...cccccccccccc"* ]]                  # stable -> candidate diff
  [[ "$output" == *"--confirm"* ]]                                           # the go action
  [[ "$output" == *"AWAITING_CONFIRMATION"* ]]
}

@test "_confirm_body: gracefully handles empty prior (no prior stable release)" {
  run env CANARY_RINGS="$RINGS" bash -c \
    "source '$ORCH' && _confirm_body dev-lead 'ring1->stable' cccccccccccc '' combsmith/.github-private 5 1"
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
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/combsmith/.github-private/issues/777" ;;
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
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" GITHUB_STEP_SUMMARY="$summ" bash "$ORCH" sync-issues
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
  run env CANARY_RINGS="$SYNC_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
  [ "$status" -eq 0 ]
  [[ "$output" == *"closed cleared confirm issue #502 for dev-lead"* ]]
  grep -q "CLOSE|.*502" "$ISSUE_LOG"
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
  run env CANARY_RINGS="$CORR_RINGS" bash -c "source '$ORCH' && _correctness_verdict dev-lead $_CORR_CAND '$(_corr_cut)' combsmith/.github-private"
  [ "$status" -eq 0 ]; [ "$output" = "SHIFT" ]
}
@test "_correctness_verdict: candidate mix matches the baseline → OK (no effect)" {
  _correctness_stub dispatched 20 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash -c "source '$ORCH' && _correctness_verdict dev-lead $_CORR_CAND '$(_corr_cut)' combsmith/.github-private"
  [ "$status" -eq 0 ]; [ "$output" = "OK" ]
}
@test "_correctness_verdict: candidate sample below the minimum → INSUFFICIENT (no-op)" {
  _correctness_stub dispatched 5 dispatched 22
  run env CANARY_RINGS="$CORR_RINGS" bash -c "source '$ORCH' && _correctness_verdict dev-lead $_CORR_CAND '$(_corr_cut)' combsmith/.github-private"
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
  "issue create"*) echo "CREATE|\$*" >> "$ISSUE_LOG"; echo "https://github.com/combsmith/.github-private/issues/777" ;;
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
  run env CANARY_RINGS="$CORR_RINGS" ISSUE_REPO="combsmith/.github-private" bash "$ORCH" sync-issues
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
  *"matching-refs/tags/dev-lead/v"*) printf 'refs/tags/dev-lead/v2.0.0\ttagobj\ttag\n' ;;
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
  grep -q "PATCH repos/combsmith/.github-private/git/refs/tags/dev-lead/v2-ring0" "$MOVE_LOG"
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
  [ -n "$V2NEXT" ] && v2next_resp="${V2NEXT}"$'\t'"commit"
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
  _f4_autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" major
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # major bump v2.1.0 → v3.0.0; the immutable release cut as usual, next seeded on the FRESH v3 line.
  grep -q "git/tags .*tag=dev-lead/v3.0.0 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/combsmith/.github-private/git/refs/tags/dev-lead/v3-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  # The fresh major line does NOT move the old bare next (that would break the running fleet).
  ! grep -q "git/refs/tags/dev-lead/next " "$GH_LOG"
}

@test "orchestrator: autocut of a patch bump advances the current major's v2-next when that line exists (#657 F4)" {
  _f4_autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" patch \
    cccccccccccccccccccccccccccccccccccccccc
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  # patch bump v2.1.0 → v2.1.1; the v2 line exists → next advances ON the major line, not bare next.
  grep -q "git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/combsmith/.github-private/git/refs/tags/dev-lead/v2-next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "git/refs/tags/dev-lead/next " "$GH_LOG"
}

@test "orchestrator: autocut of a patch bump falls back to bare next when no v-line exists yet (#657 F4)" {
  # Today's bare fleet: no v2-next tag → resolution falls back to bare next → byte-identical move.
  _f4_autocut_stub dev-lead combsmith/.github-private .github/workflows/dev-lead-reusable.yml \
    blobMAIN blobNEXT aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc "2.1.0" patch
  run env CANARY_AUTO_CUT=true CANARY_RINGS="$AUTOCUT_RINGS" bash "$ORCH" autocut
  [ "$status" -eq 0 ]
  grep -q "git/tags .*tag=dev-lead/v2.1.1 .*object=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  grep -q "PATCH repos/combsmith/.github-private/git/refs/tags/dev-lead/next .*sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$GH_LOG"
  ! grep -q "git/refs/tags/dev-lead/v2-next" "$GH_LOG"
}
