#!/usr/bin/env bats
# Fleet pause gate of the weekly compliance audit workflow (#1309).
#
# `AGENTS_PAUSED=true` is the Actions variable that pauses the agent fleet
# (petry-projects/.github-private#1525, #2249). In
# compliance-audit-and-improvement.yml only `analyze` calls a model, so only
# `analyze` carries `vars.AGENTS_PAUSED != 'true'`, and `fleet-paused` says why
# on the complementary condition. `audit` and `health-survey` call no model and
# keep running during a pause. The rule mirrors feature-ideation-reusable.yml
# (#1295): only the word `true` pauses, in any letter case; unset, `false`, `1`
# or a padded value run the workflow as before.
#
# What this suite proves, and what it cannot:
#   - It is STATIC. It parses the workflow file and evaluates each job's `if:`
#     with a small model of GitHub's expression rules (an unset variable is the
#     empty string, string equality ignores case, an `if:` with no status-check
#     function needs every dependency to succeed). The model refuses anything
#     it does not know, so a rewritten gate fails here until the test is taught.
#   - It EXECUTES the notice step's script, so the line it prints is real.
#   - It does NOT prove that GitHub still runs `analyze` after a failed
#     dependency now that `always()` is the second term, nor that a paused run
#     ends green. Only a live run can.
#
# Run: bats test/workflows/compliance-audit/fleet-pause.bats   (needs python3 + PyYAML; fails without)

load '../helpers/fleet-pause'

REAL_WF="${FP_REPO_ROOT}/.github/workflows/compliance-audit-and-improvement.yml"
WF="$REAL_WF"

# The condition `analyze` had before the gate. Everything after the gate must
# still be exactly this, or an unset variable no longer means "as before".
BEFORE="always() && (needs.audit.result == 'success' || needs.health-survey.result == 'success')"

setup() { fp_setup; }

# ── the gate ─────────────────────────────────────────────────────────────────

@test "pause gate: analyze is the only job that reaches the model, and it is gated" {
  pause model-jobs
  [ "$status" -eq 0 ]
  [ "$output" = "analyze" ]
  pause gate analyze
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "pause gate: the gate is put in front of the condition analyze already had" {
  pause if analyze
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "vars.AGENTS_PAUSED != 'true' && ${BEFORE}" ]
}

@test "pause gate: the workflow is audit, health-survey, analyze and the notice, and still grants nothing by default" {
  pause jobs
  [ "$status" -eq 0 ]
  [ "$output" = $'audit\nhealth-survey\nanalyze\nfleet-paused' ]
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "workflow_permissions={}" <<< "$output"
}

# ── skipped when true, runs when unset or false (acceptance criterion 1) ─────

@test "truth table: analyze is skipped when AGENTS_PAUSED is true, and runs when it is unset or false" {
  load_table
  [ "$(outcome analyze true)" = "skipped" ]
  [ "$(outcome analyze unset)" = "runs" ]
  [ "$(outcome analyze false)" = "runs" ]
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

# ── the dependencies: one success is enough, and no result beats the pause ───

@test "dependencies: not paused, analyze runs when at least one of audit and health-survey succeeded" {
  local audit survey want value
  for audit in success failure cancelled skipped; do
    for survey in success failure cancelled skipped; do
      load_table "audit=$audit" "health-survey=$survey"
      if [ "$audit" = success ] || [ "$survey" = success ]; then want=runs; else want=skipped; fi
      for value in unset false; do
        [ "$(outcome analyze "$value")" = "$want" ] || {
          echo "audit=$audit health-survey=$survey AGENTS_PAUSED=$value: $(outcome analyze "$value"), want $want"; return 1; }
      done
    done
  done
}

@test "dependencies: paused, analyze is skipped whatever audit and health-survey did" {
  local audit survey value
  for audit in success failure cancelled skipped; do
    for survey in success failure cancelled skipped; do
      load_table "audit=$audit" "health-survey=$survey"
      for value in true TRUE True; do
        [ "$(outcome analyze "$value")" = "skipped" ] || {
          echo "audit=$audit health-survey=$survey AGENTS_PAUSED=$value: analyze ran"; return 1; }
        # The notice needs neither job, so a failed audit cannot silence it.
        [ "$(outcome fleet-paused "$value")" = "runs" ] || {
          echo "audit=$audit health-survey=$survey AGENTS_PAUSED=$value: no notice"; return 1; }
      done
    done
  done
}

# ── the deterministic jobs keep running (acceptance criterion 3) ─────────────

@test "deterministic jobs: audit and health-survey have no condition and run for every value" {
  load_table
  local job value
  for job in audit health-survey; do
    pause if "$job"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -z "$output" ] || { echo "$job has an if: $output"; return 1; }
    for value in unset false true TRUE True 1 yes padded; do
      [ "$(outcome "$job" "$value")" = "runs" ] || { echo "$job AGENTS_PAUSED=$value: did not run"; return 1; }
    done
  done
}

# ── the notice job: what a paused run does instead of analyze ────────────────

@test "notice job: stands alone, and no job or workflow output waits on a skipped job" {
  pause notice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"if=vars.AGENTS_PAUSED == 'true'"* ]]
  [[ "$output" == *"standalone=True"* ]]
  # Nothing reads a result the paused run does not produce: only analyze has
  # dependencies, and no job waits on analyze or the notice.
  grep -qx "needs.audit=" <<< "$output"
  grep -qx "needs.health-survey=" <<< "$output"
  grep -qx "needs.analyze=audit,health-survey" <<< "$output"
  grep -qx "needs.fleet-paused=" <<< "$output"
  [ "$(grep -c '^needs\.' <<< "$output")" -eq 4 ]
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
  [[ "$output" == "::notice title=Agent fleet paused::Org Standards Compliance Audit: analysis not run, the agent fleet is paused (AGENTS_PAUSED=true)."* ]]
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

# ── the evaluator refuses what it does not know ──────────────────────────────

# probe <analyze if:> — point WF at a copy of the workflow whose `analyze`
# condition is replaced.
probe() {
  WF="${BATS_TEST_TMPDIR}/probe.yml"
  REAL="$REAL_WF" EXPR="$1" python3 -c '
import os, sys, yaml
doc = yaml.safe_load(open(os.environ["REAL"], encoding="utf-8"))
doc["jobs"]["analyze"]["if"] = os.environ["EXPR"]
yaml.safe_dump(doc, sys.stdout)' > "$WF"
}

@test "evaluator: a status-check function need not be first, and without one a failed dependency skips the job" {
  # `always()` after the gate still counts (the shape `analyze` has now).
  probe "vars.AGENTS_PAUSED != 'true' && always() && needs.health-survey.result == 'success'"
  load_table audit=failure
  [ "$(outcome analyze unset)" = "runs" ]
  [ "$(outcome analyze true)" = "skipped" ]
  # No status-check function: GitHub implies success(), so the failed audit skips it.
  probe "vars.AGENTS_PAUSED != 'true' && needs.health-survey.result == 'success'"
  load_table audit=failure
  [ "$(outcome analyze unset)" = "skipped" ]
  load_table
  [ "$(outcome analyze unset)" = "runs" ]
}

@test "evaluator: refuses a function, a context or a dependency it does not model" {
  local expr
  local -a exprs=(
    "vars.AGENTS_PAUSED != 'true' && !cancelled()"
    "vars.AGENTS_PAUSED != 'true' && failure()"
    "vars.AGENTS_PAUSED != 'true' && contains(needs.audit.result, 'success')"
    "vars.AGENTS_PAUSED != 'true' && needs.audit.outputs.findings_count != '0'"
    "vars.AGENTS_PAUSED != 'true' && needs.fleet-paused.result == 'success'"
    "vars.AGENTS_PAUSED != 'true' && github.event_name == 'schedule'"
  )
  for expr in "${exprs[@]}"; do
    probe "$expr"
    pause table
    [ "$status" -eq 3 ] || { echo "accepted: $expr"; echo "$output"; return 1; }
    [[ "$output" == "unsupported \`if:\` expression: "* ]] || { echo "$expr: $output"; return 1; }
  done
  # A result GitHub never reports is refused too, before any row is printed.
  WF="$REAL_WF"
  pause table audit=maybe
  [ "$status" -eq 2 ]
}
