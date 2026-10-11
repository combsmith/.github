#!/usr/bin/env bats
# Unit tests for the standards release-channel decision core
# (scripts/lib/standards-release.sh) and the scripts/cut-standards-release.sh
# orchestrator's pure paths (with gh/git stubbed).
#
# Issue #1091 — cut the standards release channel (standards/v1-stable).
# The channel-tag vocabulary (immutable standards/vX.Y.Z, moving
# standards/v<major>-stable, refuse-to-clobber) mirrors the org's reusable
# versioning model (standards/ci-standards.md, scripts/lib/canary-rollout.sh);
# standards are per-repo so the shape is simpler than the per-agent rings.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/standards-release.sh"
ORCH="$SCRIPT_DIR/scripts/cut-standards-release.sh"

setup() {
  # shellcheck source=/dev/null
  source "$LIB"
}

# ── tag naming ─────────────────────────────────────────────────────────────────
@test "sr_release_tag: builds the immutable release tag" {
  [ "$(sr_release_tag 1.0.0)" = "standards/v1.0.0" ]
  [ "$(sr_release_tag 2.13.4)" = "standards/v2.13.4" ]
}
@test "sr_release_tag: rejects a non-semver version" {
  run sr_release_tag v1.0.0
  [ "$status" -eq 1 ]
  run sr_release_tag 1.0
  [ "$status" -eq 1 ]
  run sr_release_tag ""
  [ "$status" -eq 1 ]
}
@test "sr_channel_tag: builds the major-scoped moving channel" {
  [ "$(sr_channel_tag 1)" = "standards/v1-stable" ]
  [ "$(sr_channel_tag 2)" = "standards/v2-stable" ]
}
@test "sr_channel_for: maps a version to its major channel" {
  [ "$(sr_channel_for 1.4.0)" = "standards/v1-stable" ]
  [ "$(sr_channel_for 3.0.1)" = "standards/v3-stable" ]
}

# ── release-suffix filter (keeps channel tags out of version math) ─────────────
@test "sr_is_release_suffix: accepts strict vX.Y.Z" {
  run sr_is_release_suffix v1.0.0
  [ "$status" -eq 0 ]
}
@test "sr_is_release_suffix: rejects the moving channel suffix" {
  run sr_is_release_suffix v1-stable
  [ "$status" -eq 1 ]
}
@test "sr_version_from_tag: extracts a bare version from a release tag" {
  [ "$(sr_version_from_tag standards/v1.2.3)" = "1.2.3" ]
}
@test "sr_version_from_tag: emits nothing for a channel tag" {
  [ -z "$(sr_version_from_tag standards/v1-stable)" ]
}

# ── semver compare / max ───────────────────────────────────────────────────────
@test "sr_semver_gt: numeric field ordering (not lexical)" {
  run sr_semver_gt 1.10.0 1.9.0
  [ "$status" -eq 0 ]
  run sr_semver_gt 1.9.0 1.10.0
  [ "$status" -eq 1 ]
}
@test "sr_semver_gt: equal is not greater" {
  run sr_semver_gt 1.0.0 1.0.0
  [ "$status" -eq 1 ]
}
@test "sr_max_version: highest among mixed/invalid tokens" {
  [ "$(sr_max_version 1.0.0 1.10.0 1.2.0 notaversion)" = "1.10.0" ]
  [ -z "$(sr_max_version onlyjunk 1.x)" ]
}
@test "leading-zero fields are rejected (no octal misread in (( )) )" {
  run sr_valid_version 1.08.0
  [ "$status" -eq 1 ]
  run sr_is_release_suffix v1.08.0
  [ "$status" -eq 1 ]
  # a non-leading-zero version still parses and compares safely
  [ "$(sr_major 1.8.0)" = "1" ]
  run sr_semver_gt 1.8.0 1.10.0
  [ "$status" -eq 1 ]
}

# ── N-1 resolvability (AC #4) ──────────────────────────────────────────────────
@test "sr_current_and_previous: two highest distinct versions" {
  run sr_current_and_previous 1.0.0 1.1.0 1.2.0
  [ "$status" -eq 0 ]
  [ "$output" = $'1.2.0\t1.1.0' ]
}
@test "sr_current_and_previous: single version → empty previous (documented starting state)" {
  run sr_current_and_previous 1.0.0
  [ "$status" -eq 0 ]
  [ "$output" = $'1.0.0\t' ]
}
@test "sr_current_and_previous: no versions → both empty" {
  run sr_current_and_previous
  [ "$status" -eq 0 ]
  [ "$output" = $'\t' ]
}
@test "sr_current_and_previous: dedups and ignores junk, orders numerically" {
  run sr_current_and_previous 1.2.0 1.2.0 1.10.0 junk 1.9.0
  [ "$output" = $'1.10.0\t1.9.0' ]
}

# ── clobber refusal (AC #3 — mirror cut-release.sh) ────────────────────────────
@test "sr_cut_decision: absent tag → CREATE" {
  [ "$(sr_cut_decision "" deadbeef)" = "CREATE" ]
}
@test "sr_cut_decision: existing tag at same commit → NOOP (idempotent)" {
  [ "$(sr_cut_decision deadbeef deadbeef)" = "NOOP" ]
}
@test "sr_cut_decision: existing tag at a different commit → REFUSE (never clobber)" {
  [ "$(sr_cut_decision deadbeef cafef00d)" = "REFUSE" ]
}

# ── orchestrator: dry-run cut is pure + resolves via channel, refuses reclobber ─
# Stub gh + git on PATH so no network/real repo state is touched.
_stub_bin() {
  STUBDIR="$(mktemp -d)"
  export PATH="$STUBDIR:$PATH"
}

@test "cut --dry-run: prints the release tag, channel move, and touches no remote" {
  _stub_bin
  # git: report a HEAD sha and no existing standards tags.
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  "for-each-ref"*) : ;;                 # no existing standards/* tags
  *) : ;;
esac
EOF
  # gh may be READ (GET) in a dry run, but must never WRITE — fail loudly on any
  # mutation verb. A missing ref read exits nonzero (as real gh does) → no tag.
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-X PATCH"*|*"-X POST"*|*"--method PATCH"*|*"--method POST"*)
    echo "gh WRITE attempted during --dry-run: $*" >&2; exit 99 ;;
esac
# read of a nonexistent ref → nonzero with a 404 (as real gh does), so
# _gh_tag_commit treats it as ABSENT rather than as an unavailable-tag error.
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.0.0 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards/v1.0.0"* ]]
  [[ "$output" == *"standards/v1-stable"* ]]
  [[ "$output" == *"aaaaaaaa"* ]]
}

@test "cut: refuses to clobber an existing release tag at a different commit" {
  _stub_bin
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;
  *) : ;;
esac
EOF
  # gh api resolving the release tag returns a DIFFERENT commit than requested.
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
# repos/<repo>/git/ref/tags/standards/v1.0.0 → an annotated/commit sha
if [[ "$*" == *"git/ref/tags/standards/v1.0.0"* ]]; then
  echo "cccccccccccccccccccccccccccccccccccccccc"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.0.0 --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSE"* || "$output" == *"refus"* ]]
}

@test "cut: a non-404 read error aborts (an unavailable tag is not treated as absent)" {
  _stub_bin
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "dddddddddddddddddddddddddddddddddddddddd" ;;
  *) : ;;
esac
EOF
  # gh read of the release ref fails with a 5xx (NOT a 404): the existing tag is
  # unavailable, not proven absent, so the cut must abort rather than CREATE.
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-X PATCH"*|*"-X POST"*) echo "gh WRITE attempted after unavailable read: $*" >&2; exit 99 ;;
esac
if [[ "$*" == *"git/ref/tags/standards/v1.0.0"* ]]; then
  echo "gh: Internal Server Error (HTTP 500)" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.0.0 --commit dddddddddddddddddddddddddddddddddddddddd
  [ "$status" -ne 0 ]
  [[ "$output" == *"unavailable"* || "$output" == *"could not resolve"* ]]
}

@test "cut: does not move the channel backward when a newer release already exists" {
  _stub_bin
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "2222222222222222222222222222222222222222" ;;
  "config --get remote.origin.url") echo "https://github.com/petry-projects/.github.git" ;;
  *) : ;;
esac
EOF
  # Cutting v1.2.0 while v1.3.0 is already published on the same major. The
  # immutable v1.2.0 tag is absent (CREATE succeeds), but the channel move must
  # be SKIPPED — a PATCH here would drag standards/v1-stable backward.
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"-X PATCH"* ]]; then
  echo "gh PATCH (channel move) attempted despite newer release: $args" >&2
  exit 99
fi
if [[ "$args" == *"git/ref/tags/standards/v1.2.0"* ]]; then
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
if [[ "$args" == *"-X POST"* && "$args" == *"git/tags"* ]]; then
  echo "1111111111111111111111111111111111111111"; exit 0
fi
if [[ "$args" == *"-X POST"* && "$args" == *"git/refs"* ]]; then
  echo "{}"; exit 0
fi
if [[ "$args" == *"matching-refs/tags/standards/v"* ]]; then
  echo "refs/tags/standards/v1.2.0"
  echo "refs/tags/standards/v1.3.0"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.2.0 --commit 2222222222222222222222222222222222222222
  [ "$status" -eq 0 ]
  [[ "$output" == *"standards/v1.3.0"* ]]
  [[ "$output" == *"skipping backward move"* ]]
}

@test "orchestrator: usage on no args, nonzero exit" {
  run bash "$ORCH"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

# ── bash 3.2 portability (AC #1, #3 — #1119) ───────────────────────────────────
# This script is operator-run from a workstation, and the likely execution
# environment is macOS whose system bash is 3.2. "CI uses a newer bash" is NOT
# sufficient coverage: the original defect (`${out,,}` in _gh_move_tag) is a
# bash-4 case-modification expansion that runs fine on the bats runner's bash but
# is a fatal "bad substitution" on bash 3.2 — which aborted the cut *after* the
# immutable release was created but *before* the channel moved. Guard both the
# orchestrator and the pure core against bash 4+ constructs so the regression
# cannot re-enter under a newer CI bash.
@test "operator scripts are free of bash 4+ constructs (must run on macOS bash 3.2)" {
  local f
  for f in "$ORCH" "$LIB"; do
    # ${var,,} / ${var,} / ${var^^} / ${var^} — bash 4 case modification.
    run grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*[,^]' "$f"
    [ "$status" -eq 1 ] || { echo "bash-4 case-modification (\${x,,}/\${x^^}) in $f:"; echo "$output"; false; }
    # declare -A / local -A — associative arrays are bash 4 only.
    run grep -nE '(declare|local|typeset)[[:space:]]+-[A-Za-z]*A' "$f"
    [ "$status" -eq 1 ] || { echo "associative array (declare -A) in $f:"; echo "$output"; false; }
    # mapfile / readarray — bash 4 only. \b is unreliable on BSD grep (macOS),
    # so match word boundaries with explicit non-word-char / anchor classes (ERE, portable).
    run grep -nE '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' "$f"
    [ "$status" -eq 1 ] || { echo "mapfile/readarray in $f:"; echo "$output"; false; }
    # &>> — append-both redirect is bash 4 only.
    run grep -nF '&>>' "$f"
    [ "$status" -eq 1 ] || { echo "&>> append-both redirect in $f:"; echo "$output"; false; }
  done
}

# ── atomic cut: no release published without its channel (AC #2, #5) ────────────
# A fresh cut must CREATE the immutable release AND move the moving channel onto
# the same commit. The bash-3.2 defect left the release created and the channel
# absent; this asserts the channel is created (PATCH miss → POST fallback) in the
# same run, so no consumer is left pinning a channel that 404s.
@test "cut: a fresh cut creates the release and moves the channel onto the same commit" {
  _stub_bin
  export GH_CALLS="$STUBDIR/gh-calls.log"
  : > "$GH_CALLS"
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "5555555555555555555555555555555555555555" ;;
  *) : ;;
esac
EOF
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$GH_CALLS"
# release tag read → genuinely absent (HTTP 404) → CREATE path
if [[ "$args" == *"git/ref/tags/standards/v1.0.0"* ]]; then
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
# create the immutable annotated tag object
if [[ "$args" == *"-X POST"* && "$args" == *"git/tags"* ]]; then
  echo "1111111111111111111111111111111111111111"; exit 0
fi
# channel PATCH → the channel ref does not exist yet → _gh_move_tag falls back to POST
if [[ "$args" == *"-X PATCH"* && "$args" == *"git/refs/tags/standards/v1-stable"* ]]; then
  echo "gh: Reference does not exist (HTTP 404)" >&2; exit 1
fi
# publish any ref (release ref + channel ref create)
if [[ "$args" == *"-X POST"* && "$args" == *"git/refs"* ]]; then
  echo "{}"; exit 0
fi
# enumerate published releases: only v1.0.0, so this cut is the highest on v1
if [[ "$args" == *"matching-refs/tags/standards/v"* ]]; then
  echo "refs/tags/standards/v1.0.0"; exit 0
fi
exit 0
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.0.0 --commit 5555555555555555555555555555555555555555
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating immutable release standards/v1.0.0"* ]]
  [[ "$output" == *"moving channel standards/v1-stable"* ]]
  [[ "$output" == *"done."* ]]
  # The channel ref was actually created in the same run (no stranded release),
  # and it points at THIS cut's commit — assert the SHA too, not just the ref
  # name, so a wrong-commit POST cannot pass this same-commit test.
  grep -q "POST .*git/refs .*refs/tags/standards/v1-stable.*sha=5555555555555555555555555555555555555555" "$GH_CALLS"
}

# Re-running the exact same cut must stay NOOP on the immutable release (never
# re-create / clobber it) yet still converge the channel (AC #5 idempotency +
# the recoverability contract that makes a partial cut self-healing on re-run).
@test "cut: re-running at the same commit is NOOP on the release and still converges the channel" {
  _stub_bin
  export GH_CALLS="$STUBDIR/gh-calls.log"
  : > "$GH_CALLS"
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "5555555555555555555555555555555555555555" ;;
  *) : ;;
esac
EOF
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$GH_CALLS"
# release tag already resolves to the requested commit → NOOP
if [[ "$args" == *"git/ref/tags/standards/v1.0.0"* ]]; then
  echo "5555555555555555555555555555555555555555"; exit 0
fi
# a POST to git/tags would mean the immutable release is being re-created — forbid it
if [[ "$args" == *"-X POST"* && "$args" == *"git/tags"* ]]; then
  echo "release re-create attempted on NOOP: $args" >&2; exit 99
fi
# channel already exists → PATCH force-move succeeds
if [[ "$args" == *"-X PATCH"* && "$args" == *"git/refs/tags/standards/v1-stable"* ]]; then
  echo "{}"; exit 0
fi
if [[ "$args" == *"matching-refs/tags/standards/v"* ]]; then
  echo "refs/tags/standards/v1.0.0"; exit 0
fi
exit 0
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.0.0 --commit 5555555555555555555555555555555555555555
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOOP"* ]]
  [[ "$output" != *"creating immutable release"* ]] || { echo "release creation output on NOOP" >&2; return 1; }
  [[ "$output" == *"moving channel standards/v1-stable"* ]]
  [[ "$output" == *"done."* ]]
  # The channel was converged via a force-move PATCH; no release re-create happened.
  grep -q "PATCH .*git/refs/tags/standards/v1-stable.*sha=5555555555555555555555555555555555555555" "$GH_CALLS"
  ! grep -q -e "-X POST .*git/tags" "$GH_CALLS" || { echo "release re-create request on NOOP" >&2; return 1; }
}

# A partial cut — immutable release published, channel move persistently failing —
# must exit NONZERO and print the exact rerun recovery guidance (#1119). The
# fresh-cut and idempotency scenarios only exercise a SUCCEEDING move (PATCH miss
# → POST fallback, and PATCH hit); neither reaches _gh_move_tag's nonzero branch,
# so this asserts the failure status and the operator-facing recovery message.
@test "cut: a persistent channel-move failure returns nonzero and prints the rerun recovery guidance" {
  _stub_bin
  cat > "$STUBDIR/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "6666666666666666666666666666666666666666" ;;
  *) : ;;
esac
EOF
  cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
# release tag read → genuinely absent (HTTP 404) → CREATE path
if [[ "$args" == *"git/ref/tags/standards/v1.0.0"* ]]; then
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
# create the immutable annotated tag object (release IS published)
if [[ "$args" == *"-X POST"* && "$args" == *"git/tags"* ]]; then
  echo "1111111111111111111111111111111111111111"; exit 0
fi
# publish the release ref → succeeds (so the immutable release exists)
if [[ "$args" == *"-X POST"* && "$args" == *"git/refs"* ]]; then
  echo "{}"; exit 0
fi
# channel move PATCH → persistent NON-404 failure: _gh_move_tag cannot recover
# (it does not fall back to POST on a non-"not found" error) → the cut is partial
if [[ "$args" == *"-X PATCH"* && "$args" == *"git/refs/tags/standards/v1-stable"* ]]; then
  echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1
fi
# this cut is the highest on the v1 line (so the move is attempted, not skipped)
if [[ "$args" == *"matching-refs/tags/standards/v"* ]]; then
  echo "refs/tags/standards/v1.0.0"; exit 0
fi
exit 0
EOF
  chmod +x "$STUBDIR/git" "$STUBDIR/gh"
  run bash "$ORCH" cut v1.0.0 --commit 6666666666666666666666666666666666666666
  [ "$status" -ne 0 ]
  [[ "$output" == *"partial cut"* ]]
  [[ "$output" == *"could NOT be moved"* ]]
  # The recovery guidance must emit the complete rerun command with the exact version
  # and commit as a shell-executable token with the actual script path quoted.
  grep -q "Re-run \"$ORCH\" cut 1.0.0 --commit 6666666666666666666666666666666666666666" <<< "$output"
}

# ── pre-promotion verification (#1173) ─────────────────────────────────────────
# A promotion is fleet-wide with no canary stage, so every known channel consumer
# is run against the candidate commit first. The consumer list is data.
CONSUMERS="$SCRIPT_DIR/scripts/lib/standards-channel-consumers.json"
CAND_SHA="9999999999999999999999999999999999999999"

@test "sr_consumer_verdict: a zero exit with the expected output is PASS" {
  printf 'a.yml\tALIGNED\tx\ty\tN\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" $'\tALIGNED\t' '::error')" = "PASS" ]
}
@test "sr_consumer_verdict: a non-zero exit fails and names the code" {
  printf 'whatever\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 3 "$BATS_TEST_TMPDIR/out" "" "")" = "FAIL exit-3" ]
}
@test "sr_consumer_verdict: a zero exit with rejected output fails" {
  printf 'a.yml\tALIGNED\tx\ty\tN\n::error::boom\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" $'\tALIGNED\t' '::error')" = "FAIL rejected-output" ]
}
@test "sr_consumer_verdict: a zero exit without the expected output fails" {
  printf 'nothing happened\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" '^OK: [0-9]+' "")" = "FAIL expected-output-missing" ]
}
@test "sr_consumer_verdict: no exit code means the consumer never ran" {
  [ "$(sr_consumer_verdict "" "$BATS_TEST_TMPDIR/none" "" "")" = "FAIL not-run" ]
}
@test "sr_consumer_verdict: unreadable output fails" {
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/does-not-exist" "" "")" = "FAIL output-unreadable" ]
}
@test "sr_consumer_verdict: with no patterns a zero exit passes" {
  : > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" "" "")" = "PASS" ]
}

@test "consumer list: every row has id, repo, ref_env and command, and ids are unique" {
  run jq -e '
    (.consumers | length) > 0
    and all(.consumers[];
      (.id | type == "string" and length > 0)
      and (.repo | type == "string" and test("^[^/]+/[^/]+$"))
      and (.ref_env | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$"))
      and (.command | type == "string" and length > 0))
    and ((.consumers | map(.id) | unique | length) == (.consumers | length))
  ' "$CONSUMERS"
  [ "$status" -eq 0 ]
}

@test "consumer list: the drift guard's patterns reject a run that skipped every file (hollow green)" {
  local expect reject
  expect="$(jq -r '.consumers[] | select(.id == "template-stub-drift") | .expect_output' "$CONSUMERS")"
  reject="$(jq -r '.consumers[] | select(.id == "template-stub-drift") | .reject_output' "$CONSUMERS")"
  # The guard exits 0 when it cannot compute a file's baseline: it warns and skips.
  printf '::warning::Could not compute the standards-derived content for CLAUDE.md at N (x) — skipping its drift check.\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" "$expect" "$reject")" = "FAIL rejected-output" ]
  printf '.github/CODEOWNERS\tALIGNED\taaa\taaa\tN\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" "$expect" "$reject")" = "PASS" ]
  printf '.github/CODEOWNERS\tALIGNED\taaa\taaa\tN\nCLAUDE.md\tDRIFTED\tbbb\taaa\t\n' > "$BATS_TEST_TMPDIR/out"
  [ "$(sr_consumer_verdict 0 "$BATS_TEST_TMPDIR/out" "$expect" "$reject")" = "FAIL rejected-output" ]
}

# _verify_env <check.sh body> — a gh stub that resolves any ref to CAND_SHA (or
# prints $GH_SHA_REPLY when set) and refuses every write, a fake consumer checkout
# "consumer-a" whose check.sh has the given body, and a one-row consumer list
# pointing at it.
_verify_env() {
  _stub_bin
  export GH_SHA_REPLY="${GH_SHA_REPLY-$CAND_SHA}"
  cat > "$STUBDIR/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$*" in
  *"-X PATCH"*|*"-X POST"*) echo "gh WRITE attempted: $*" >&2; exit 99 ;;
  *"application/vnd.github.sha"*) printf '%s' "$GH_SHA_REPLY" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
GHSTUB
  cat > "$STUBDIR/git" <<'GITSTUB'
#!/usr/bin/env bash
case "$*" in
  "rev-parse HEAD") echo "9999999999999999999999999999999999999999" ;;
  *) : ;;
esac
GITSTUB
  chmod +x "$STUBDIR/gh" "$STUBDIR/git"
  export SR_CONSUMERS_ROOT="$STUBDIR/consumers"
  mkdir -p "$SR_CONSUMERS_ROOT/consumer-a"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$SR_CONSUMERS_ROOT/consumer-a/check.sh"
  export SR_CONSUMERS_FILE="$STUBDIR/consumers.json"
  cat > "$SR_CONSUMERS_FILE" <<'CONSUMERSJSON'
{"consumers":[{"id":"a-check","repo":"petry-projects/consumer-a","ref_env":"A_REF","command":"bash check.sh","expect_output":"^checked at [0-9a-f]{40}$","reject_output":"::error"}]}
CONSUMERSJSON
}

@test "verify: a passing consumer is run pinned to the resolved commit SHA" {
  _verify_env 'echo "checked at $A_REF"'
  run bash "$ORCH" verify main
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidate: main -> 999999999999"* ]]
  [[ "$output" == *"a-check"*"PASS"* ]]
  [[ "$output" == *"verified: all 1 channel consumer(s) pass"* ]]
}

@test "verify: a consumer that exits non-zero fails verification and its output is shown" {
  _verify_env 'echo "schema rejects manifest x"; exit 1'
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"a-check"*"FAIL exit-1"* ]]
  [[ "$output" == *"schema rejects manifest x"* ]]
  [[ "$output" == *"1 of 1 channel consumer(s) failed"* ]]
}

@test "verify: a consumer that exits 0 without doing its work fails (no hollow green)" {
  _verify_env 'echo "skipped: could not read the ref"'
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL expected-output-missing"* ]]
}

@test "verify: one failing consumer fails the run even when another passes" {
  _verify_env 'echo "checked at $A_REF"'
  mkdir -p "$SR_CONSUMERS_ROOT/consumer-b"
  printf '#!/usr/bin/env bash\nexit 4\n' > "$SR_CONSUMERS_ROOT/consumer-b/check.sh"
  cat > "$SR_CONSUMERS_FILE" <<'CONSUMERSJSON'
{"consumers":[
  {"id":"a-check","repo":"petry-projects/consumer-a","ref_env":"A_REF","command":"bash check.sh","expect_output":"^checked at"},
  {"id":"b-check","repo":"petry-projects/consumer-b","ref_env":"B_REF","command":"bash check.sh"}
]}
CONSUMERSJSON
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"a-check"*"PASS"* ]]
  [[ "$output" == *"b-check"*"FAIL exit-4"* ]]
  [[ "$output" == *"1 of 2 channel consumer(s) failed"* ]]
}

@test "verify: a consumer whose checkout is unavailable fails, it is not skipped" {
  _verify_env 'echo "checked at $A_REF"'
  rm -rf "$SR_CONSUMERS_ROOT/consumer-a"
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL checkout-unavailable"* ]]
}

@test "verify: a malformed consumer row fails" {
  _verify_env 'echo "checked at $A_REF"'
  echo '{"consumers":[{"id":"a-check","repo":"petry-projects/consumer-a","ref_env":"NOT VALID","command":"bash check.sh"}]}' > "$SR_CONSUMERS_FILE"
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL malformed-entry"* ]]
}

@test "verify: an empty consumer list is an error, not a pass" {
  _verify_env 'echo "checked at $A_REF"'
  echo '{"consumers":[]}' > "$SR_CONSUMERS_FILE"
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot verify"* ]]
}

@test "verify: an unreadable consumer list is an error, not a pass" {
  _verify_env 'echo "checked at $A_REF"'
  export SR_CONSUMERS_FILE="$STUBDIR/missing.json"
  run bash "$ORCH" verify main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot verify"* ]]
}

@test "verify: a ref that does not resolve to a commit is an error and runs no consumer" {
  GH_SHA_REPLY='{"message":"No commit found for SHA: nope","status":"422"}'
  _verify_env 'echo ran > "$0.ran"; echo "checked at $A_REF"'
  run bash "$ORCH" verify nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve 'nope'"* ]]
  [ ! -e "$SR_CONSUMERS_ROOT/consumer-a/check.sh.ran" ]
}

@test "cut --verify: refuses to cut when a consumer fails, and writes no tag" {
  _verify_env 'echo "manifest invalid"; exit 1'
  run bash "$ORCH" cut v1.2.0 --verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSE to cut standards/v1.2.0"* ]]
  [[ "$output" != *"gh WRITE attempted"* ]]
  [[ "$output" != *"creating immutable release"* ]]
}

@test "cut --verify --dry-run: verifies, then previews without writing" {
  _verify_env 'echo "checked at $A_REF"'
  run bash "$ORCH" cut v1.2.0 --verify --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified: all 1 channel consumer(s) pass"* ]]
  [[ "$output" == *"[dry-run] no tags written."* ]]
}

@test "cut without --verify does not run the consumers (existing behaviour)" {
  _verify_env 'echo ran > "$0.ran"; echo "checked at $A_REF"'
  run bash "$ORCH" cut v1.2.0 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"candidate:"* ]]
  [ ! -e "$SR_CONSUMERS_ROOT/consumer-a/check.sh.ran" ]
}
