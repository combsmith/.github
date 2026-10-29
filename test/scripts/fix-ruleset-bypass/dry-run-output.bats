#!/usr/bin/env bats
# Dry-run output safety for scripts/fix-ruleset-bypass.sh (#1388):
#   - the default OUT_DIR is a fresh, private mktemp -d directory (never a
#     fixed, predictable path under a shared temp dir);
#   - an explicit OUT_DIR is honored;
#   - an existing symlink at a payload path is refused, never written through.
# gh is stubbed; no network, no real token.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
FIX="$SCRIPT_DIR/scripts/fix-ruleset-bypass.sh"

setup() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  WORK="$(mktemp -d)"
  # Isolated TMPDIR so the default-OUT_DIR assertions only see this test's dirs.
  export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
  export GH_TOKEN="stub-not-a-token"
  unset OUT_DIR
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"rulesets/7"*)
    echo '{"id":7,"name":"Protect Main","target":"branch","enforcement":"active",
           "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
           "rules":[],"bypass_actors":[]}' ;;
  *"/rulesets"*) echo '[{"id":7}]' ;;
  *"repos/combsmith/"*) echo 'main' ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"
}
teardown() { rm -rf "${STUB_BIN:-}" "${WORK:-}"; return 0; }

_payload_path() { printf '%s\n' "$1" | sed -n 's/^ *payload: //p'; }

@test "default OUT_DIR is a fresh mktemp dir, not the fixed predictable path" {
  # A pre-planted entry at the old fixed path must be ignored entirely.
  mkdir -p "$TMPDIR/petry-ruleset-payloads"
  ln -s "$WORK/victim" "$TMPDIR/petry-ruleset-payloads/demo__protect-main.json"

  run "$FIX" demo --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/victim" ]

  local out
  out=$(_payload_path "$output")
  [ -n "$out" ]
  [ -f "$out" ] && [ ! -L "$out" ]
  case "$out" in "$TMPDIR/petry-ruleset-payloads/"*) false ;; esac
  # mktemp -d creates the directory owner-only (0700).
  local dir mode
  dir=$(dirname "$out")
  mode=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")
  [ "$mode" = "700" ]
  jq -e '.bypass_actors | length == 2' "$out"
}

@test "two default runs use distinct directories" {
  run "$FIX" demo --dry-run
  [ "$status" -eq 0 ]
  local a b
  a=$(_payload_path "$output")
  run "$FIX" demo --dry-run
  [ "$status" -eq 0 ]
  b=$(_payload_path "$output")
  [ -n "$a" ] && [ -n "$b" ]
  [ "$(dirname "$a")" != "$(dirname "$b")" ]
}

@test "explicit OUT_DIR is honored" {
  OUT_DIR="$WORK/mine" run "$FIX" demo --dry-run
  [ "$status" -eq 0 ]
  [ -f "$WORK/mine/demo__protect-main.json" ]
  [ ! -L "$WORK/mine/demo__protect-main.json" ]
  [ "$(_payload_path "$output")" = "$WORK/mine/demo__protect-main.json" ]
}

@test "explicit OUT_DIR: an existing regular payload file is replaced" {
  mkdir -p "$WORK/mine"
  echo stale > "$WORK/mine/demo__protect-main.json"
  OUT_DIR="$WORK/mine" run "$FIX" demo --dry-run
  [ "$status" -eq 0 ]
  jq -e '.name == "Protect Main"' "$WORK/mine/demo__protect-main.json"
}

@test "refuses to write a payload through a pre-planted symlink" {
  mkdir -p "$WORK/shared"
  echo original > "$WORK/victim"
  ln -s "$WORK/victim" "$WORK/shared/demo__protect-main.json"

  OUT_DIR="$WORK/shared" run "$FIX" demo --dry-run
  [ "$status" -ne 0 ]
  [ "$(cat "$WORK/victim")" = "original" ]
  [ -L "$WORK/shared/demo__protect-main.json" ]
  [[ "$output" == *"symlink"* ]]
}

@test "refuses a dangling pre-planted symlink (would create the target)" {
  mkdir -p "$WORK/shared"
  ln -s "$WORK/created-by-attacker-link" "$WORK/shared/demo__protect-main.json"

  OUT_DIR="$WORK/shared" run "$FIX" demo --dry-run
  [ "$status" -ne 0 ]
  [ ! -e "$WORK/created-by-attacker-link" ]
}
