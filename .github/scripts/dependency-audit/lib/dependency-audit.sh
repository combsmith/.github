#!/usr/bin/env bash
# Discovery, coverage and gate logic for the dependency-audit reusable workflow
# (.github/workflows/dependency-audit-reusable.yml).
#
# The reusable checks this repo out at its own commit (`job.workflow_sha`) and
# sources this file, so the logic always matches the pinned workflow version.
# The workflow steps are thin glue: they install the scanners and call the
# runners below. Everything that decides WHAT gets audited, and whether the run
# as a whole passed, lives here so it is covered by bats
# (test/workflows/dependency-audit/) instead of being trapped inline in YAML.
#
# External commands are resolved through PATH (`cargo`, `pip-audit`, `jq`,
# `find`, `sort`), so tests substitute stubs for the scanners.
#
# Paths are handled NUL-delimited end to end: a directory name may legally
# contain a newline, and a newline-split record would point the guards at a
# path that does not exist and silently skip the real project (#1404).
#
# Compatible with bash 3.2+ (no associative arrays, no `mapfile -d`).
#
# Issues: #1393 (Cargo coverage), #1394 (committed Cargo.lock), #1404 (Python
# discovery), #1406 (aggregate gate).

# dep_audit_display PATH
#   Prints PATH with CR and LF escaped as \r and \n, for log lines and workflow
#   commands. A raw newline in a crafted directory name would otherwise end the
#   `::group::` line and start a new line the runner parses as a command.
dep_audit_display() {
  local s="$1"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# dep_audit_dirs_of_files
#   Reads NUL-delimited file paths on stdin and prints the NUL-delimited, sorted,
#   de-duplicated set of their parent directories.
dep_audit_dirs_of_files() {
  local f
  while IFS= read -r -d '' f; do
    case "$f" in
      */*) printf '%s\0' "${f%/*}" ;;
      *) printf '.\0' ;;
    esac
  done | LC_ALL=C sort -z -u
}

# dep_audit_python_projects ROOT
#   Prints, NUL-delimited, every directory under ROOT that holds a
#   pyproject.toml or requirements.txt (regular file or symlink), skipping
#   virtualenvs (*/.venv/*, */venv/*). Non-zero if the walk itself fails, so an
#   unreadable subtree is not mistaken for "no projects there".
dep_audit_python_projects() {
  local root="$1"
  (
    set -o pipefail
    find "$root" \( -name 'pyproject.toml' -o -name 'requirements.txt' \) \
      \( -type f -o -type l \) \
      -not -path '*/.venv/*' -not -path '*/venv/*' -print0 |
      dep_audit_dirs_of_files
  )
}

# dep_audit_python_run ROOT
#   Runs pip-audit for every Python project under ROOT: `pip-audit DIR` when the
#   directory has a pyproject.toml and `pip-audit -r DIR/requirements.txt` when
#   it has a requirements.txt (both when both are present). Returns non-zero if
#   discovery fails, any audit fails, or a discovered project cannot be audited
#   — an unprocessable project is an error, never a silent skip (#1404).
dep_audit_python_run() {
  local root="$1" list dir shown audited status=0
  list="$(mktemp)" || return 1
  if ! dep_audit_python_projects "$root" >"$list"; then
    echo "::error::Python project discovery failed under $(dep_audit_display "$root")"
    rm -f "$list"
    return 1
  fi
  while IFS= read -r -d '' -u 3 dir; do
    shown="$(dep_audit_display "$dir")"
    echo "::group::pip-audit ${shown}"
    audited=0
    if [ -f "$dir/pyproject.toml" ]; then
      audited=1
      pip-audit "$dir" </dev/null || status=1
    fi
    if [ -f "$dir/requirements.txt" ]; then
      audited=1
      pip-audit -r "$dir/requirements.txt" </dev/null || status=1
    fi
    echo "::endgroup::"
    if [ "$audited" -eq 0 ]; then
      echo "::error::Discovered Python project ${shown} but found no readable pyproject.toml or requirements.txt to audit"
      status=1
    fi
  done 3<"$list"
  rm -f "$list"
  return "$status"
}

# dep_audit_cargo_manifest_dirs ROOT
#   Prints, NUL-delimited and sorted, every directory under ROOT that holds a
#   Cargo.toml, skipping build output (*/target/*). Non-zero if the walk fails.
dep_audit_cargo_manifest_dirs() {
  local root="$1"
  (
    set -o pipefail
    find "$root" -name 'Cargo.toml' \( -type f -o -type l \) \
      -not -path '*/target/*' -print0 |
      dep_audit_dirs_of_files
  )
}

# dep_audit_cargo_workspace_root
#   Reads `cargo metadata --no-deps --format-version 1` JSON on stdin and prints
#   its `workspace_root` verbatim (no trailing newline). Non-zero when the field
#   is missing, empty or not a string.
#
#   `workspace_root` is Cargo's own answer to "which lockfile covers this
#   manifest": the enclosing workspace for a member, the crate itself for a
#   standalone crate or one the enclosing workspace `exclude`s. Directory
#   ancestry is not that answer (#1393).
dep_audit_cargo_workspace_root() {
  jq -j -e '.workspace_root | select(type == "string" and length > 0)'
}

# dep_audit_cargo_audit_roots ROOT
#   Prints, NUL-delimited, the de-duplicated workspace roots that together
#   cover every Cargo.toml under ROOT, in manifest order. Each manifest is
#   resolved with `cargo metadata --no-deps` (no network, no lockfile write).
#   A manifest Cargo cannot resolve is reported with `::error::` and makes the
#   function return non-zero; every resolvable root is still printed, so the
#   caller can audit what it can and fail the job.
dep_audit_cargo_audit_roots() {
  local root="$1" list dir meta ws seen s status=0
  local -a roots=()
  list="$(mktemp)" || return 1
  if ! dep_audit_cargo_manifest_dirs "$root" >"$list"; then
    echo "::error::Cargo manifest discovery failed under $(dep_audit_display "$root")" >&2
    rm -f "$list"
    return 1
  fi
  while IFS= read -r -d '' -u 3 dir; do
    if ! meta="$(cargo metadata --no-deps --format-version 1 \
      --manifest-path "$dir/Cargo.toml" </dev/null)"; then
      echo "::error::cargo metadata failed for $(dep_audit_display "$dir")/Cargo.toml; cannot tell which lockfile covers it, so it cannot be audited" >&2
      status=1
      continue
    fi
    # Sentinel keeps a trailing newline in the path intact through $(...).
    ws="$(printf '%s' "$meta" | dep_audit_cargo_workspace_root && printf x)"
    if [ "${ws%x}" = "$ws" ] || [ -z "${ws%x}" ]; then
      echo "::error::cargo metadata for $(dep_audit_display "$dir")/Cargo.toml has no workspace_root" >&2
      status=1
      continue
    fi
    ws="${ws%x}"
    seen=0
    for s in ${roots[@]+"${roots[@]}"}; do
      if [ "$s" = "$ws" ]; then
        seen=1
        break
      fi
    done
    if [ "$seen" -eq 0 ]; then
      roots+=("$ws")
      printf '%s\0' "$ws"
    fi
  done 3<"$list"
  rm -f "$list"
  return "$status"
}

# dep_audit_cargo_audit_dir DIR
#   Audits the lockfile in DIR. A committed Cargo.lock is audited exactly as
#   committed — regenerating it first would audit whatever versions resolve
#   today instead of the reviewed ones (#1394). Only when DIR has no Cargo.lock
#   (typically a library crate) is one generated so there is something to audit.
dep_audit_cargo_audit_dir() {
  local dir="$1"
  (
    cd -- "$dir" || exit 1
    if [ ! -e Cargo.lock ]; then
      echo "No committed Cargo.lock in $(dep_audit_display "$dir"); generating one to audit."
      if ! cargo generate-lockfile </dev/null; then
        echo "::error::cargo generate-lockfile failed in $(dep_audit_display "$dir")"
        exit 1
      fi
    fi
    cargo audit </dev/null
  )
}

# dep_audit_cargo_run ROOT
#   Audits every workspace root that covers a Cargo.toml under ROOT. Non-zero
#   if any manifest could not be resolved or any audit fails.
dep_audit_cargo_run() {
  local root="$1" list dir status=0
  list="$(mktemp)" || return 1
  dep_audit_cargo_audit_roots "$root" >"$list" || status=1
  while IFS= read -r -d '' -u 3 dir; do
    echo "::group::cargo audit $(dep_audit_display "$dir")"
    dep_audit_cargo_audit_dir "$dir" || status=1
    echo "::endgroup::"
  done 3<"$list"
  rm -f "$list"
  return "$status"
}

# dep_audit_gate_verdict
#   Reads the reusable's `toJSON(needs)` on stdin — {job_id: {result, outputs}}
#   for the detect job and every audit job — and prints one "job: result" line
#   per job. Returns 0 only when `detect` succeeded and every other job either
#   succeeded or was skipped (its ecosystem is absent). `failure`, `cancelled`,
#   a missing result, malformed input or a missing `detect` entry all fail:
#   this is the status that can stand in for the whole audit (#1406).
dep_audit_gate_verdict() {
  local pairs job result status=0 saw_detect=0
  if ! pairs="$(jq -r -e '
      if type == "object" and length > 0 then
        to_entries[] | "\(.key)\t\(.value.result // "missing")"
      else
        error("needs is not a non-empty object")
      end')"; then
    echo "::error::Audit gate could not read the needed jobs' results"
    return 1
  fi
  while IFS=$'\t' read -r job result; do
    [ -n "$job" ] || continue
    echo "${job}: ${result}"
    if [ "$job" = "detect" ]; then
      saw_detect=1
      if [ "$result" != "success" ]; then
        echo "::error::Ecosystem detection did not succeed (${result}); no audit can be trusted"
        status=1
      fi
      continue
    fi
    case "$result" in
      success | skipped) ;;
      *)
        echo "::error::Dependency audit job '${job}' did not pass (${result})"
        status=1
        ;;
    esac
  done <<EOF
$pairs
EOF
  if [ "$saw_detect" -eq 0 ]; then
    echo "::error::Audit gate saw no result for the detect job"
    status=1
  fi
  return "$status"
}
