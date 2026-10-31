#!/usr/bin/env bats
# Tests for .github/scripts/dependency-audit/lib/dependency-audit.sh and the
# steps of .github/workflows/dependency-audit-reusable.yml that call it.
#
# Pins:
#   #1393  a crate the parent workspace `exclude`s (or that is not a member) is
#          audited on its own, not dropped because it sits under the
#          workspace directory.
#   #1394  a committed Cargo.lock is audited as committed, never regenerated.
#   #1404  Python discovery is NUL-delimited; a directory whose name contains a
#          newline is audited, and an unprocessable project fails the job.
#   #1406  the aggregate `Audit gate` job fails when any audit failed or was
#          cancelled, and depends on every audit job.

load 'helpers/setup'

setup() {
  da_setup_stubs
  # shellcheck source=/dev/null
  . "$DA_LIB"
  WS="${BATS_TEST_TMPDIR}/ws"
  REPO="${WS}/repo"
  mkdir -p "$REPO"
}

# A Cargo workspace at $REPO with one member (crates/member) and one crate it
# excludes (tools/excluded), each with its own committed lockfile state.
make_cargo_fixture() {
  mkdir -p "$REPO/crates/member" "$REPO/tools/excluded"
  cat >"$REPO/Cargo.toml" <<'TOML'
[workspace]
members = ["crates/*"]
exclude = ["tools/excluded"]
TOML
  echo '# workspace lock: clean' >"$REPO/Cargo.lock"
  printf '[package]\nname = "member"\nversion = "0.1.0"\n' >"$REPO/crates/member/Cargo.toml"
  printf '[package]\nname = "excluded"\nversion = "0.1.0"\n' >"$REPO/tools/excluded/Cargo.toml"
  # Committed lockfile pins a vulnerable version.
  echo '# excluded lock: VULN pinned' >"$REPO/tools/excluded/Cargo.lock"
  da_ws_member "$REPO/crates/member" "$REPO"
  da_ws_member "$REPO" "$REPO"
}

# ── display ──────────────────────────────────────────────────────────────────

@test "display: escapes CR and LF so a path cannot start a new log line" {
  run dep_audit_display $'a\nb\rc'
  [ "$status" -eq 0 ]
  [ "$output" = 'a\nb\rc' ]
}

# ── Python discovery (#1404) ────────────────────────────────────────────────

@test "python discovery: a directory name with a newline is one NUL-delimited record" {
  mkdir -p "$REPO/svc"$'\n'"api" "$REPO/both" "$REPO/.venv/lib" "$REPO/x/venv/y"
  touch "$REPO/svc"$'\n'"api/requirements.txt" "$REPO/both/pyproject.toml" \
    "$REPO/both/requirements.txt" "$REPO/.venv/lib/pyproject.toml" \
    "$REPO/x/venv/y/requirements.txt"
  cd "$REPO"
  local got=() d
  while IFS= read -r -d '' d; do got+=("$d"); done < <(dep_audit_python_projects .)
  [ "${#got[@]}" -eq 2 ]
  [ "${got[0]}" = "./both" ]
  [ "${got[1]}" = "./svc"$'\n'"api" ]
}

@test "python discovery: a directory named like a manifest is not a project" {
  mkdir -p "$REPO/requirements.txt"
  cd "$REPO"
  run dep_audit_python_projects .
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "python run: a vulnerable project under a newline-named directory fails the audit" {
  mkdir -p "$REPO/svc"$'\n'"api"
  echo 'VULN==1.0' >"$REPO/svc"$'\n'"api/requirements.txt"
  cd "$REPO"
  run dep_audit_python_run .
  [ "$status" -eq 1 ]
  da_calls | grep -qF 'pip-audit -r ./svc\napi/requirements.txt'
}

@test "python run: audits pyproject.toml AND requirements.txt when both exist" {
  mkdir -p "$REPO/both"
  touch "$REPO/both/pyproject.toml" "$REPO/both/requirements.txt"
  cd "$REPO"
  run dep_audit_python_run .
  [ "$status" -eq 0 ]
  da_calls | grep -qxF "pip-audit ./both @ $(pwd -P)"
  da_calls | grep -qxF "pip-audit -r ./both/requirements.txt @ $(pwd -P)"
}

@test "python run: a discovered project with no readable manifest fails instead of skipping" {
  mkdir -p "$REPO/broken"
  ln -s does-not-exist "$REPO/broken/requirements.txt"
  cd "$REPO"
  run dep_audit_python_run .
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Discovered Python project ./broken"* ]]
  [ ! -s "$CALLS" ]
}

@test "python run: a discovery failure fails the audit" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 directory"
  mkdir -p "$REPO/locked/inner"
  touch "$REPO/locked/inner/requirements.txt"
  chmod 000 "$REPO/locked"
  cd "$REPO"
  run dep_audit_python_run .
  chmod 755 "$REPO/locked"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Python project discovery failed"* ]]
}

@test "python run: a crafted directory name cannot emit a workflow command line" {
  mkdir -p "$REPO/x"$'\n'"::error::injected"
  touch "$REPO/x"$'\n'"::error::injected/requirements.txt"
  cd "$REPO"
  run dep_audit_python_run .
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cx '::error::injected')" -eq 0 ]
  [[ "$output" == *'::group::pip-audit ./x\n::error::injected'* ]]
}

# ── Cargo coverage (#1393) ──────────────────────────────────────────────────

@test "cargo workspace_root: extracts the field verbatim" {
  run dep_audit_cargo_workspace_root <<<'{"workspace_root":"/w/a\nb","packages":[]}'
  [ "$status" -eq 0 ]
  [ "$output" = "/w/a"$'\n'"b" ]
}

@test "cargo workspace_root: missing, empty or non-string is an error" {
  run dep_audit_cargo_workspace_root <<<'{"packages":[]}'
  [ "$status" -ne 0 ]
  run dep_audit_cargo_workspace_root <<<'{"workspace_root":""}'
  [ "$status" -ne 0 ]
  run dep_audit_cargo_workspace_root <<<'{"workspace_root":7}'
  [ "$status" -ne 0 ]
}

@test "cargo roots: an excluded crate under the workspace dir is its own audit root" {
  make_cargo_fixture
  cd "$REPO"
  local got=() d
  while IFS= read -r -d '' d; do got+=("$d"); done < <(dep_audit_cargo_audit_roots .)
  [ "${#got[@]}" -eq 2 ]
  [ "${got[0]}" = "$(pwd -P)" ]
  [ "${got[1]}" = "$(pwd -P)/tools/excluded" ]
}

@test "cargo roots: build output under target/ is ignored" {
  mkdir -p "$REPO/target/debug/build/x"
  printf '[package]\nname = "x"\n' >"$REPO/target/debug/build/x/Cargo.toml"
  cd "$REPO"
  run dep_audit_cargo_audit_roots .
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cargo roots: a manifest cargo cannot resolve fails, other roots still listed" {
  make_cargo_fixture
  (cd "$REPO/tools/excluded" && pwd -P) >>"$CARGO_METADATA_FAIL"
  cd "$REPO"
  local out="${BATS_TEST_TMPDIR}/roots" err="${BATS_TEST_TMPDIR}/roots.err" rc=0
  dep_audit_cargo_audit_roots . >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  grep -qF '::error::cargo metadata failed for ./tools/excluded/Cargo.toml' "$err"
  [ "$(tr '\0' '\n' <"$out")" = "$(pwd -P)" ]
}

@test "cargo run: excluded crate is audited and its vulnerable committed lock fails the job" {
  make_cargo_fixture
  cd "$REPO"
  run dep_audit_cargo_run .
  [ "$status" -eq 1 ]
  da_calls | grep -qxF "cargo audit @ $(pwd -P)/tools/excluded"
  # Member crates are covered by the workspace audit, not re-audited.
  [ "$(da_calls | grep -c '^cargo audit ')" -eq 2 ]
}

# ── Cargo lockfile (#1394) ──────────────────────────────────────────────────

@test "cargo audit dir: a committed Cargo.lock is audited as committed" {
  mkdir -p "$REPO/c"
  echo '# VULN pinned' >"$REPO/c/Cargo.lock"
  run dep_audit_cargo_audit_dir "$REPO/c"
  [ "$status" -eq 1 ]
  [ "$(da_calls | grep -c generate-lockfile)" -eq 0 ]
  [ "$(cat "$REPO/c/Cargo.lock")" = '# VULN pinned' ]
}

@test "cargo audit dir: with no Cargo.lock one is generated, then audited" {
  mkdir -p "$REPO/lib"
  run dep_audit_cargo_audit_dir "$REPO/lib"
  [ "$status" -eq 0 ]
  [ "$(da_calls | sed 's/ @ .*//')" = "$(printf 'cargo generate-lockfile\ncargo audit')" ]
}

# ── Gate verdict (#1406) ────────────────────────────────────────────────────

@test "gate: detect success with audits success/skipped passes" {
  run dep_audit_gate_verdict <<<'{"detect":{"result":"success","outputs":{}},
    "audit-npm":{"result":"success"},"audit-pnpm":{"result":"skipped"},
    "audit-go":{"result":"skipped"},"audit-cargo":{"result":"success"},
    "audit-pip":{"result":"skipped"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit-cargo: success"* ]]
}

@test "gate: a failed audit fails the gate" {
  run dep_audit_gate_verdict <<<'{"detect":{"result":"success"},"audit-pip":{"result":"failure"}}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::Dependency audit job 'audit-pip' did not pass (failure)"* ]]
}

@test "gate: a cancelled audit fails the gate" {
  run dep_audit_gate_verdict <<<'{"detect":{"result":"success"},"audit-go":{"result":"cancelled"}}'
  [ "$status" -eq 1 ]
}

@test "gate: detect anything but success fails, even when audits were skipped" {
  local r
  for r in failure cancelled skipped; do
    run dep_audit_gate_verdict <<<"{\"detect\":{\"result\":\"$r\"},\"audit-npm\":{\"result\":\"skipped\"}}"
    [ "$status" -eq 1 ]
  done
}

@test "gate: missing detect, missing result or malformed input fails closed" {
  run dep_audit_gate_verdict <<<'{"audit-npm":{"result":"success"}}'
  [ "$status" -eq 1 ]
  run dep_audit_gate_verdict <<<'{"detect":{"result":"success"},"audit-npm":{}}'
  [ "$status" -eq 1 ]
  run dep_audit_gate_verdict <<<'{}'
  [ "$status" -eq 1 ]
  run dep_audit_gate_verdict <<<'not json'
  [ "$status" -eq 1 ]
  run dep_audit_gate_verdict </dev/null
  [ "$status" -eq 1 ]
}

# ── Workflow wiring ─────────────────────────────────────────────────────────

@test "workflow: audit gate needs detect and every other job, and always runs" {
  local jobs needs
  jobs="$(yq -r '.jobs | keys | .[] | select(. != "audit-gate")' "$DA_WORKFLOW" | sort)"
  needs="$(yq -r '.jobs["audit-gate"].needs[]' "$DA_WORKFLOW" | sort)"
  [ -n "$jobs" ]
  [ "$jobs" = "$needs" ]
  [ "$(yq -r '.jobs["audit-gate"].if' "$DA_WORKFLOW")" = 'always()' ]
  [ "$(yq -r '.jobs["audit-gate"].name' "$DA_WORKFLOW")" = 'Audit gate' ]
}

@test "workflow: the required 'Detect ecosystems' job keeps its name" {
  [ "$(yq -r '.jobs.detect.name' "$DA_WORKFLOW")" = 'Detect ecosystems' ]
}

@test "workflow: tooling is checked out from the reusable's own commit, outside the scanned tree" {
  local job
  for job in audit-cargo audit-pip audit-gate; do
    # shellcheck disable=SC2016 # the literal expression text is what is pinned
    [ "$(JOB=$job yq -r '.jobs[strenv(JOB)].steps[] | select(.with.repository == "combsmith/.github") | .with.ref' "$DA_WORKFLOW")" = '${{ job.workflow_sha }}' ]
    [ "$(JOB=$job yq -r '.jobs[strenv(JOB)].steps[] | select(.with.repository == "combsmith/.github") | .with.path' "$DA_WORKFLOW")" = '.dependency-audit-tooling' ]
  done
  for job in audit-cargo audit-pip; do
    [ "$(JOB=$job yq -r '.jobs[strenv(JOB)].steps[0].with.path' "$DA_WORKFLOW")" = 'repo' ]
  done
}

@test "workflow step: Audit Cargo dependencies audits the excluded crate's committed lock" {
  make_cargo_fixture
  run da_run_step audit-cargo "Audit Cargo dependencies" "$WS"
  [ "$status" -ne 0 ]
  [ "$(da_calls | grep -c generate-lockfile)" -eq 0 ]
  da_calls | grep -qxF "cargo audit @ $(cd "$REPO/tools/excluded" && pwd -P)"
  [ "$(cat "$REPO/tools/excluded/Cargo.lock")" = '# excluded lock: VULN pinned' ]
}

@test "workflow step: Audit Python dependencies fails on a vulnerable newline-named project" {
  mkdir -p "$REPO/svc"$'\n'"api"
  echo 'VULN==1.0' >"$REPO/svc"$'\n'"api/requirements.txt"
  run da_run_step audit-pip "Audit Python dependencies" "$WS"
  [ "$status" -ne 0 ]
  da_calls | grep -qF 'requirements.txt'
}

@test "workflow step: Require every audit to pass fails when an audit failed" {
  export NEEDS_JSON='{"detect":{"result":"success"},"audit-cargo":{"result":"failure"}}'
  run da_run_step audit-gate "Require every audit to pass" "$WS"
  [ "$status" -eq 1 ]
  export NEEDS_JSON='{"detect":{"result":"success"},"audit-cargo":{"result":"skipped"}}'
  run da_run_step audit-gate "Require every audit to pass" "$WS"
  [ "$status" -eq 0 ]
}

@test "workflow: every setup-python step uses the pinned python-version input, defaulting to a concrete minor" {
  default="$(yq -r '.on.workflow_call.inputs["python-version"].default' "$DA_WORKFLOW")"
  [[ "$default" =~ ^3\.[0-9]+$ ]]
  versions="$(yq -r '.jobs[].steps[] | select(.uses // "" | test("^actions/setup-python@")) | .with["python-version"]' "$DA_WORKFLOW")"
  [ -n "$versions" ]
  while IFS= read -r v; do
    [ "$v" = '${{ inputs.python-version }}' ]
  done <<<"$versions"
}
