#!/usr/bin/env bats
# Cleanup scope for scripts/sonarcloud-audit.sh (#1409): auto-closing "resolved"
# audit issues must only touch repos that THIS run selected and successfully
# scanned. A repo excluded by TARGET_REPO (or with no SonarCloud project) has no
# findings in groups.json simply because it was not scanned — that is not
# evidence its findings were resolved.
#
# SonarCloud fetches are replaced by function overrides and gh is a PATH stub
# that serves one marker-bearing open audit issue per repo and logs closes.
# No network, no real token.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/sonarcloud-audit.sh"

setup() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  : > "$CALLS"
  REPORT_DIR="$(mktemp -d)"; export REPORT_DIR
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "repo list"*) printf '%s\n' target-repo other-repo no-sonar-repo ;;
  "issue list"*"--label sonarcloud-audit"*)
    repo=""; prev=""
    for a in "$@"; do [ "$prev" = "--repo" ] && repo="${a#combsmith/}"; prev="$a"; done
    printf '[{"number":11,"body":"<!-- sonarcloud-audit:key=%s/shell -->"}]\n' "$repo" ;;
  "issue close"*) echo "$args" >> "$CALLS" ;;
  *) echo "" ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"
}
teardown() { rm -rf "${STUB_BIN:-}" "${REPORT_DIR:-}"; return 0; }

# _run_main [fail-project] — source the script, stub the SonarCloud fetches
# (two projects, zero findings; optionally one project's fetch fails), run main.
_run_main() {
  run bash -c '
    source "$1"
    sonar_list_projects() { printf "%s\n" combsmith_target-repo combsmith_other-repo; }
    sonar_project_issues() {
      [ "$1" = "${FAIL_PROJECT:-}" ] && { warn "fetch failed for $1"; return 1; }
      echo "[]"
    }
    main
  ' _ "$SCRIPT"
}

# _not_closed <repo> — no close was issued in <repo>. (A bare `! grep` mid-test
# does not fail a bats test; a function's return status does.)
_not_closed() { ! grep -q -- "--repo combsmith/$1 " "$CALLS"; }

@test "TARGET_REPO run closes only the targeted repo's resolved issues" {
  TARGET_REPO=target-repo _run_main
  [ "$status" -eq 0 ]
  grep -q -- '--repo combsmith/target-repo' "$CALLS"
  _not_closed other-repo
  _not_closed no-sonar-repo
}

@test "TARGET_REPO given as owner/name is honored the same way" {
  TARGET_REPO=combsmith/target-repo _run_main
  [ "$status" -eq 0 ]
  grep -q -- '--repo combsmith/target-repo' "$CALLS"
  _not_closed other-repo
}

@test "full run closes resolved issues in scanned repos, never in unscanned ones" {
  TARGET_REPO="" _run_main
  [ "$status" -eq 0 ]
  grep -q -- '--repo combsmith/target-repo' "$CALLS"
  grep -q -- '--repo combsmith/other-repo' "$CALLS"
  # In the org but has no SonarCloud project: never scanned, never "resolved".
  _not_closed no-sonar-repo
}

@test "a TARGET_REPO with no matching project closes nothing" {
  TARGET_REPO=no-sonar-repo _run_main
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "a failed project fetch closes nothing anywhere" {
  FAIL_PROJECT=combsmith_other-repo TARGET_REPO="" _run_main
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}
