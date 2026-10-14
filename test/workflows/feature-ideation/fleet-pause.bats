#!/usr/bin/env bats
# Fleet pause gate of the reusable feature-ideation workflow (#1295).
#
# `AGENTS_PAUSED=true` is the Actions variable that pauses the agent fleet
# (combsmith/.github-private#1525, #2249). The caller stubs are frozen, so
# the gate lives in feature-ideation-reusable.yml: every job but the notice
# carries `vars.AGENTS_PAUSED != 'true'`, and `fleet-paused` says why on the
# complementary condition. The rule mirrors .github-private: only the word
# `true` pauses, in any letter case (GitHub compares strings without regard to
# case); unset, `false`, `1` or a padded value run the workflow as before.
#
# What this suite proves, and what it cannot:
#   - It is STATIC. It parses the workflow file and evaluates each job's `if:`
#     with a small model of GitHub's expression rules (an unset variable is the
#     empty string, string equality ignores case). The model refuses anything
#     it does not know, so a rewritten gate fails here until the test is taught.
#   - It EXECUTES the notice step's script, so the line it prints is real.
#   - It does NOT prove that GitHub hands the calling repository's (or the
#     organisation's) variables to a `workflow_call` job, nor that a paused run
#     ends green. Only a live run with the variable set can.
#
# Run: bats test/workflows/feature-ideation/fleet-pause.bats   (needs python3 + PyYAML; fails without)

load 'helpers/setup'
load '../helpers/fleet-pause'

WF="${TT_REPO_ROOT}/.github/workflows/feature-ideation-reusable.yml"

# The evaluator and the `pause`, `load_table` and `outcome` helpers are shared
# with the other fleet-pause suites: test/workflows/helpers/fleet-pause.bash.
setup() { fp_setup; }

# ── the gate ─────────────────────────────────────────────────────────────────

@test "pause gate: analyze is the job that reaches the model, and it is gated" {
  pause model-jobs
  [ "$status" -eq 0 ]
  [ "$output" = "analyze" ]
  pause gate analyze
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "pause gate: every job but the notice is gated, so a paused run starts nothing else" {
  pause jobs
  [ "$status" -eq 0 ]
  local job n=0
  local -a jobs=()
  while IFS= read -r job; do jobs+=("$job"); done <<< "$output"
  for job in "${jobs[@]}"; do
    [ "$job" = "fleet-paused" ] && continue
    pause gate "$job"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    n=$((n + 1))
  done
  # gather-signals only feeds analyze; skipping it too leaves no orphan artifact.
  [ "$n" -eq 2 ]
  [[ " ${jobs[*]} " == *" gather-signals "* ]]
  [[ " ${jobs[*]} " == *" analyze "* ]]
}

# ── skipped when true, runs when unset or false (acceptance criterion 1) ─────

@test "truth table: analyze is skipped when AGENTS_PAUSED is true, and runs when it is unset or false" {
  load_table
  [ "$(outcome analyze true)" = "skipped" ]
  [ "$(outcome analyze unset)" = "runs" ]
  [ "$(outcome analyze false)" = "runs" ]
}

@test "truth table: gather-signals follows analyze for every value" {
  load_table
  local value
  for value in unset false true TRUE True 1 yes padded; do
    [ -n "$(outcome analyze "$value")" ] || { echo "no row for analyze/$value"; return 1; }
    [ "$(outcome gather-signals "$value")" = "$(outcome analyze "$value")" ] || {
      echo "gather-signals and analyze differ for AGENTS_PAUSED=$value"; return 1; }
  done
}

@test "truth table: only the word true pauses, in any letter case" {
  load_table
  local value
  for value in TRUE True; do
    [ "$(outcome analyze "$value")" = "skipped" ] || { echo "AGENTS_PAUSED=$value did not pause"; return 1; }
  done
  for value in 1 yes padded; do
    [ "$(outcome analyze "$value")" = "runs" ] || { echo "AGENTS_PAUSED=$value paused"; return 1; }
  done
}

@test "truth table: fleet-paused is the exact complement of analyze" {
  load_table
  local value want
  for value in unset false true TRUE True 1 yes padded; do
    if [ "$(outcome analyze "$value")" = "skipped" ]; then want=runs; else want=skipped; fi
    [ "$(outcome fleet-paused "$value")" = "$want" ] || {
      echo "fleet-paused AGENTS_PAUSED=$value: $(outcome fleet-paused "$value"), want $want"; return 1; }
  done
}

# ── the notice job: what a paused run does instead ───────────────────────────

@test "notice job: stands alone, and no job or workflow output waits on a skipped job" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"if=vars.AGENTS_PAUSED == 'true'"* ]]
  [[ "$output" == *"standalone=True"* ]]
  # Nothing reads a result the paused run does not produce: analyze waits on
  # gather-signals (both skipped), and no job waits on analyze or the notice.
  grep -qx "needs.gather-signals=" <<< "$output"
  grep -qx "needs.analyze=gather-signals" <<< "$output"
  grep -qx "needs.fleet-paused=" <<< "$output"
  [ "$(grep -c '^needs\.' <<< "$output")" -eq 3 ]
  grep -qx "workflow_outputs=" <<< "$output"
}

@test "notice job: it runs while paused, so it holds no secret, token, action or permission" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "permissions={}" <<< "$output"
  grep -qx "shell_only=True" <<< "$output"
  grep -qx "secret_refs=False" <<< "$output"
  grep -qx "model_signal=False" <<< "$output"
}

@test "notice job: the pause variables reach the script through env, never \${{ }} in run:" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF 'env_source=${{ vars.AGENTS_PAUSE_SOURCE }}' <<< "$output"
  grep -qxF 'env_until=${{ vars.AGENTS_PAUSE_UNTIL }}' <<< "$output"
  grep -qx "expression_in_run=False" <<< "$output"
}

@test "notice: prints one ::notice line naming the pause source and until time" {
  pause notice-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local script="$output"
  PAUSE_SOURCE=rate-limit-observed PAUSE_UNTIL=2026-10-13T16:00:00Z run bash -c "$script"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "::notice title=Agent fleet paused::Feature Ideation: not run, the agent fleet is paused (AGENTS_PAUSED=true)."* ]]
  [[ "$output" == *" Pause source: rate-limit-observed. Paused until: 2026-10-13T16:00:00Z." ]]
}

@test "notice: an unset source and until time read as not set (a pause set by hand)" {
  pause notice-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local script="$output"
  PAUSE_SOURCE='' PAUSE_UNTIL='' run bash -c "$script"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *" Pause source: not set (paused by hand). Paused until: not set." ]]
}

@test "notice: a line break in a value cannot start a second workflow command" {
  pause notice-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local script="$output"
  PAUSE_SOURCE=$'by hand\n::error title=injected::boom' PAUSE_UNTIL=$'soon\r\n::stop-commands::x' \
    run bash -c "$script"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "::notice title=Agent fleet paused::"* ]]
  # The hostile text is still there, as data inside the one notice.
  [[ "$output" == *"Pause source: by hand ::error title=injected::boom."* ]]
  [[ "$output" != *$'\r'* ]]
}
