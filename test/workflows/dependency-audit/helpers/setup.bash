#!/usr/bin/env bash
# Common helpers for the dependency-audit bats suite.
#
# Scanners are replaced by stubs on PATH that record every call:
#   cargo      metadata  -> answers workspace_root from $CARGO_WS_MAP
#                            ("<manifest dir>\t<workspace root>" lines, both as
#                            `pwd -P` prints them); the manifest's own directory
#                            when it is not listed. Fails for a manifest dir
#                            listed in $CARGO_METADATA_FAIL.
#              generate-lockfile -> writes a clean Cargo.lock
#              audit     -> fails when ./Cargo.lock contains "VULN"
#   pip-audit  fails when the audited pyproject.toml / requirements file
#              contains "VULN"
# Calls are appended to $CALLS, one record per call, NUL-terminated, as
#   "<tool> <args...> @ <cwd>".

DA_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DA_LIB="${DA_REPO_ROOT}/.github/scripts/dependency-audit/lib/dependency-audit.sh"
DA_WORKFLOW="${DA_REPO_ROOT}/.github/workflows/dependency-audit-reusable.yml"
export DA_REPO_ROOT DA_LIB DA_WORKFLOW

da_setup_stubs() {
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  CARGO_WS_MAP="${BATS_TEST_TMPDIR}/ws-map"
  CARGO_METADATA_FAIL="${BATS_TEST_TMPDIR}/metadata-fail"
  mkdir -p "$STUB_BIN"
  : >"$CALLS"
  : >"$CARGO_WS_MAP"
  : >"$CARGO_METADATA_FAIL"
  export STUB_BIN CALLS CARGO_WS_MAP CARGO_METADATA_FAIL

  cat >"$STUB_BIN/cargo" <<'STUB'
#!/usr/bin/env bash
printf 'cargo %s @ %s\0' "$*" "$(pwd -P)" >>"$CALLS"
case "$1" in
  metadata)
    manifest=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--manifest-path" ] && manifest="$2"
      shift
    done
    dir="$(cd -- "${manifest%/*}" && pwd -P)" || exit 101
    if grep -qxF -- "$dir" "$CARGO_METADATA_FAIL"; then
      echo "error: failed to parse manifest" >&2
      exit 101
    fi
    ws="$dir"
    while IFS=$'\t' read -r m r; do
      [ "$m" = "$dir" ] && ws="$r"
    done <"$CARGO_WS_MAP"
    jq -n --arg ws "$ws" '{packages: [], workspace_root: $ws}'
    ;;
  generate-lockfile)
    echo "# generated: clean" >Cargo.lock
    ;;
  audit)
    [ -f Cargo.lock ] || { echo "error: no Cargo.lock" >&2; exit 1; }
    ! grep -q VULN Cargo.lock
    ;;
  *) exit 2 ;;
esac
STUB

  cat >"$STUB_BIN/pip-audit" <<'STUB'
#!/usr/bin/env bash
printf 'pip-audit %s @ %s\0' "$*" "$(pwd -P)" >>"$CALLS"
if [ "$1" = "-r" ]; then
  target="$2"
else
  target="$1/pyproject.toml"
fi
[ -f "$target" ] || exit 2
! grep -q VULN "$target"
STUB
  chmod +x "$STUB_BIN/cargo" "$STUB_BIN/pip-audit"
  PATH="${STUB_BIN}:${PATH}"
  export PATH
}

# Prints the recorded calls, one per line, with embedded newlines shown as \n.
da_calls() {
  local c
  while IFS= read -r -d '' c; do
    printf '%s\n' "${c//$'\n'/\\n}"
  done <"$CALLS"
}

# da_ws_member MANIFEST_DIR WORKSPACE_DIR — tell the cargo stub that the crate
# in MANIFEST_DIR belongs to the workspace rooted at WORKSPACE_DIR.
da_ws_member() {
  printf '%s\t%s\n' "$(cd -- "$1" && pwd -P)" "$(cd -- "$2" && pwd -P)" >>"$CARGO_WS_MAP"
}

# da_step_script JOB_ID STEP_NAME — prints the `run:` script of that step of
# the reusable workflow, exactly as committed.
da_step_script() {
  JOB="$1" STEP="$2" yq -r \
    '.jobs[strenv(JOB)].steps[] | select(.name == strenv(STEP)) | .run' \
    "$DA_WORKFLOW"
}

# da_run_step JOB_ID STEP_NAME WORKSPACE — runs that step the way the runner
# does (`bash -e`, in the step's working-directory under WORKSPACE), with the
# tooling checkout at WORKSPACE/.dependency-audit-tooling pointing at this repo.
da_run_step() {
  local job="$1" step="$2" ws="$3" wd script
  script="${BATS_TEST_TMPDIR}/step.sh"
  da_step_script "$job" "$step" >"$script"
  [ -s "$script" ] || { echo "step '$step' not found in job '$job'" >&2; return 99; }
  wd="$(JOB="$job" STEP="$step" yq -r \
    '.jobs[strenv(JOB)].steps[] | select(.name == strenv(STEP)) | .["working-directory"] // ""' \
    "$DA_WORKFLOW")"
  ln -sfn "$DA_REPO_ROOT" "$ws/.dependency-audit-tooling"
  (cd -- "$ws/${wd:-.}" && bash -e "$script")
}
