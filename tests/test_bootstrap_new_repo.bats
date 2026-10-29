#!/usr/bin/env bats
# Unit tests for scripts/bootstrap-new-repo.sh — the DRY_RUN-aware bootstrap that
# orchestrates the existing apply-* scripts to bring a new repo to full org
# compliance (issue #967, epic #964). Mirrors tests/test_apply_rulesets.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BOOTSTRAP="$SCRIPT_DIR/scripts/bootstrap-new-repo.sh"

setup() {
  STUB_BIN="$(mktemp -d)" || { echo "Failed to create STUB_BIN" >&2; exit 1; }
  export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  STUB_DIR="$(mktemp -d)" || { echo "Failed to create STUB_DIR" >&2; exit 1; }
  # Fleet rulesets (code-quality, pr-quality) now live in combsmith/.github
  # (relocated under #575), so the REAL apply-rulesets.sh runs in fleet mode. Point
  # it at a local fixture so resolution needs no network; the authoritative content
  # is validated in .github. release-channel-tags stays repo-local and is NOT
  # applied by bootstrap.
  FLEET_DIR="$(mktemp -d)" || { echo "Failed to create FLEET_DIR" >&2; exit 1; }
  printf '{"name":"code-quality","target":"branch","enforcement":"active"}\n' > "$FLEET_DIR/code-quality.json"
  printf '{"name":"pr-quality","target":"branch","enforcement":"active"}\n'   > "$FLEET_DIR/pr-quality.json"
  export FLEET_RULESETS_DIR="$FLEET_DIR"
  # Canonical apply-repo-settings.sh (combsmith/.github) requires a token and
  # fetches current state even under dry-run (to diff). gh is stubbed, so this dummy
  # is never used for a real call — it only satisfies the guard.
  export GH_TOKEN=dummy
}
teardown() {
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${STUB_DIR:-}" ] && rm -rf "$STUB_DIR"
  [ -n "${FLEET_DIR:-}" ] && rm -rf "$FLEET_DIR"
  return 0
}

# gh stub: records every write (POST/PUT/PATCH/label create) to $CALLS; returns a
# non-empty stub object for reads so the orchestration never fails on a read. The
# object is deliberately non-"{}" (canonical apply-repo-settings.sh treats "{}" as a
# failed settings fetch and aborts) and carries NONE of the desired setting values,
# so every dry-run diff still prints its full intent.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*|*"PATCH"*|*"label create"*|*"-X PUT"*)
    echo "\$args" >> "$CALLS"
    echo '{"full_name":"stub/repo"}'
    ;;
  *"contents/personas/"*"/persona.yml"*)
    # Per-persona manifest read (raw). labels.sh takes the declared
    # opt_out_label rather than guessing the <id>:hands-off convention.
    printf 'id: dev-lead\nstatus: active\nopt_out_label: dev-lead:hands-off\n'
    ;;
  *"contents/personas"*)
    # Persona listing: labels.sh pipes this through
    # jq '.[]? | select(.type == "dir") | .name'. Return one persona dir so the
    # derived <id>:hands-off family resolves. An empty listing is a deliberate
    # fail-closed derivation failure (#1139), so a test that wants that path sets
    # STUB_PERSONA_LISTING='[]' instead of relying on the default.
    if [ -n "\${STUB_PERSONA_LISTING+set}" ]; then
      echo "\$STUB_PERSONA_LISTING"
    else
      echo '[{"name":"dev-lead","type":"dir"},{"name":"README.md","type":"file"}]'
    fi
    ;;
  *)
    echo '{"full_name":"stub/repo"}'
    ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# Stub the two sub-scripts so behavior (exit code) is deterministic. Each stub
# logs its invocation to $CALLS and exits with $1 (default 0).
_stub_substeps() {
  local settings_rc="${1:-0}" rulesets_rc="${2:-0}"
  cat > "$STUB_DIR/apply-repo-settings.sh" <<EOF
#!/usr/bin/env bash
echo "apply-repo-settings called: \$*" >> "$CALLS"
exit $settings_rc
EOF
  cat > "$STUB_DIR/apply-rulesets.sh" <<EOF
#!/usr/bin/env bash
echo "apply-rulesets called: \$*" >> "$CALLS"
exit $rulesets_rc
EOF
  chmod +x "$STUB_DIR/apply-repo-settings.sh" "$STUB_DIR/apply-rulesets.sh"
  export APPLY_REPO_SETTINGS="$STUB_DIR/apply-repo-settings.sh"
  export APPLY_RULESETS="$STUB_DIR/apply-rulesets.sh"
}

# NOTE: the codified pr-quality.json / code-quality.json shape assertions moved out
# of this suite with the JSONs themselves — the fleet rulesets are now owned by
# combsmith/.github (standards/rulesets/, relocated under #575) and their
# content is validated there. This suite covers bootstrap's ORCHESTRATION: that it
# applies exactly the two fleet rulesets (via fleet-mode apply-rulesets.sh) and not
# the repo-local release-channel-tags.

# ── orchestration: DRY_RUN path ───────────────────────────────────────────────
@test "DRY_RUN: exits 0 and makes no write API calls" {
  _stub_gh
  run env DRY_RUN=true bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "DRY_RUN: prints intent and a PASS summary" {
  _stub_gh
  run env DRY_RUN=true bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"DRY_RUN"* ]]
  [[ "$output" == *"owner/new-repo"* ]]
  [[ "$output" == *"PASS"* ]]
}

@test "DRY_RUN: bridges the flag onto both sub-scripts (DEV_LEAD_DRY_RUN + DRY_RUN)" {
  # Use real sub-scripts but a gh stub; in dry-run neither makes write calls.
  _stub_gh
  run env DRY_RUN=true bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  # apply-repo-settings dry-run prints its own intent line; apply-rulesets too.
  [[ "$output" == *"apply-rulesets"* ]] || [[ "$output" == *"rulesets"* ]]
}

# ── persona opt-out family: fail closed on an empty listing (#1139) ─────────────
# An org always has personas, so an empty manifest listing means the <id>:hands-off
# family could not be derived. apply-repo-settings.sh must fail rather than report
# success, and bootstrap must surface that as a FAIL. This is the path the DRY_RUN
# tests above hit by accident before the stub returned a real listing (#1318).
@test "persona fail-closed: an empty persona listing fails the bootstrap" {
  _stub_gh
  run env DRY_RUN=true STUB_PERSONA_LISTING='[]' bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be derived faithfully"* ]]
  [[ "$output" == *"FAIL"* ]]
  [ ! -f "$CALLS" ]
}

# ── orchestration: sequencing + fail-fast + summary ───────────────────────────
@test "sequence: invokes apply-repo-settings then apply-rulesets --repo on success" {
  _stub_gh
  _stub_substeps 0 0
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  grep -q "apply-repo-settings called" "$CALLS"
  grep -q "apply-rulesets called: --repo owner/new-repo" "$CALLS"
  # order: settings line must precede rulesets line
  settings_ln="$(grep -n 'apply-repo-settings called' "$CALLS" | head -1 | cut -d: -f1)"
  rulesets_ln="$(grep -n 'apply-rulesets called' "$CALLS" | head -1 | cut -d: -f1)"
  [ "$settings_ln" -lt "$rulesets_ln" ]
}

@test "fail-fast: apply-repo-settings failure stops before apply-rulesets and exits non-zero" {
  _stub_gh
  _stub_substeps 1 0
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -ne 0 ]
  grep -q "apply-repo-settings called" "$CALLS"
  ! grep -q "apply-rulesets called" "$CALLS"
  [[ "$output" == *"FAIL"* ]]
}

@test "fail-fast: apply-rulesets failure exits non-zero with a FAIL summary" {
  _stub_gh
  _stub_substeps 0 1
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -ne 0 ]
  grep -q "apply-rulesets called" "$CALLS"
  [[ "$output" == *"FAIL"* ]]
}

@test "summary: success prints a PASS summary naming the repo" {
  _stub_gh
  _stub_substeps 0 0
  run bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"owner/new-repo"* ]]
}

# ── argument handling ─────────────────────────────────────────────────────────
@test "errors when no repo argument is given" {
  _stub_gh
  run bash "$BOOTSTRAP"
  [ "$status" -ne 0 ]
}

@test "errors when the repo argument is not owner/repo" {
  _stub_gh
  run bash "$BOOTSTRAP" acme-service
  [ "$status" -eq 2 ]
  [[ "$output" == *"owner/new-repo"* ]]
}

# ── repo-settings target: owner/repo, never a doubled owner (#1308) ───────────
# bootstrap takes owner/repo; apply-repo-settings.sh takes a bare name and prefixes
# ORG itself. Passing owner/repo straight through sent every step-2 call to
# repos/<owner>/<owner>/<repo>. This wraps the normal stub so any doubled-owner
# path gets what real gh gives it — the 404 body on stdout and a non-zero exit —
# and runs the REAL apply-repo-settings.sh, so the argument is actually exercised.
_stub_gh_rejecting_doubled_owner() {
  _stub_gh
  mv "$STUB_BIN/gh" "$STUB_BIN/gh-inner"
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_BIN/gh-args.log"
if printf '%s' "\$*" | grep -qE 'repos/([^/ ]+)/\1/'; then
  echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
  echo 'gh: Not Found (HTTP 404)' >&2
  exit 1
fi
exec "$STUB_BIN/gh-inner" "\$@"
EOF
  chmod +x "$STUB_BIN/gh"
}

@test "repo settings act on repos/<owner>/<repo> and name it once (#1308)" {
  _stub_gh_rejecting_doubled_owner
  run env DRY_RUN=true bash "$BOOTSTRAP" combsmith/acme-service
  [ "$status" -eq 0 ]
  grep -q 'repos/combsmith/acme-service' "$STUB_BIN/gh-args.log"
  [ -z "$(grep -E 'repos/([^/ ]+)/\1/' "$STUB_BIN/gh-args.log")" ]
  [[ "$output" == *"Applying standard settings to combsmith/acme-service"* ]]
  [[ "$output" != *"combsmith/combsmith"* ]]
}

# ── release-ring confirmation + registration (#968) ───────────────────────────
# A throwaway copy of the real ring SoT so non-stable tests can assert intent
# without mutating the tracked file.
_ring_sot_copy() {
  RING_SOT="$STUB_DIR/canary-rings.json"
  cp "$SCRIPT_DIR/standards/canary-rings.json" "$RING_SOT"
  export CANARY_RINGS="$RING_SOT"
}

@test "ring: defaults to stable and records an auditable decision (record-only)" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  run env GITHUB_ACTOR=octocat bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ring-audit]"* ]]
  [[ "$output" == *"ring=stable"* ]]
  [[ "$output" == *"operator=octocat"* ]]
  [[ "$output" == *"decision=recorded"* ]]
  # stable is record-only: no central-file edit intent, SoT untouched
  [[ "$output" != *"would add owner/new-repo"* ]]
  run diff "$SCRIPT_DIR/standards/canary-rings.json" "$RING_SOT"
  [ "$status" -eq 0 ]
}

@test "ring: rejects an unknown ring value" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  run bash "$BOOTSTRAP" --ring nope owner/new-repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown ring"* ]]
}

@test "ring: non-stable (DRY_RUN) records the decision and prints both-file + stub intent" {
  # Real sub-scripts under dry-run make no writes, so $CALLS stays a pure
  # gh-write ledger (a stubbed sub-script would log to it and break the check).
  _stub_gh
  _ring_sot_copy
  run env DRY_RUN=true GITHUB_ACTOR=octocat bash "$BOOTSTRAP" --ring ring1 owner/new-repo
  [ "$status" -eq 0 ]
  # auditable record, even in dry-run
  [[ "$output" == *"[ring-audit]"* ]]
  [[ "$output" == *"ring=ring1"* ]]
  [[ "$output" == *"decision=registered"* ]]
  # central file 1: this repo's canary-rings.json
  [[ "$output" == *"would add owner/new-repo"* ]]
  [[ "$output" == *"ring1"* ]]
  # central file 2: cross-repo ring-pins.sh in combsmith/.github
  [[ "$output" == *"ring-pins.sh"* ]]
  [[ "$output" == *"combsmith/.github"* ]]
  # stub repin to the matching channel tag
  [[ "$output" == *"@dev-lead/ring1"* ]]
  # dry-run makes no write API calls and does not mutate the SoT
  [ ! -f "$CALLS" ]
  run diff "$SCRIPT_DIR/standards/canary-rings.json" "$RING_SOT"
  [ "$status" -eq 0 ]
}

@test "ring: non-stable consistency holds — repo lands in the named ring and no other" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  # Proposed post-state must place owner/new-repo in ring1 and nowhere else.
  run env DRY_RUN=true bash "$BOOTSTRAP" --ring ring1 owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"ring consistency OK"* ]]
}

# ── end-to-end DRY_RUN validation: the full policy surface in one run (#970) ────
# A single DRY_RUN walkthrough with the REAL sub-scripts (only `gh` stubbed) must
# describe the entire intended state — recorded ring, repo settings + GHAS + push
# protection, both sanctioned rulesets, the standard labels, CODEOWNERS team — and
# emit zero write API calls (no drift). This is the executable form of the
# end-to-end validation recorded in docs/bootstrap/new-repo-validation.md.
@test "e2e DRY_RUN: covers the whole intended-state surface with no write calls (#970 AC #2/#3)" {
  _stub_gh
  _ring_sot_copy
  run env DRY_RUN=true GITHUB_ACTOR=octocat CANARY_RINGS="$RING_SOT" \
    bash "$BOOTSTRAP" combsmith/acme-service
  [ "$status" -eq 0 ]

  # (1/5) ring — auditable record, default stable, record-only.
  [[ "$output" == *"[ring-audit]"* ]]
  [[ "$output" == *"ring=stable"* ]]
  [[ "$output" == *"decision=recorded"* ]]

  # (2/5) repo settings — security_and_analysis + secret-scanning push protection,
  # and the Claude/CodeRabbit check-suite auto-trigger disable.
  [[ "$output" == *"security_and_analysis"* ]]
  [[ "$output" == *"secret_scanning_push_protection"* ]]
  # canonical apply-repo-settings.sh exercises the check-suite auto-trigger step and,
  # under dry-run, marks it skip (message wording: "... check-suite prefs ...").
  [[ "$output" == *"check-suite prefs"* ]]

  # (3/5) exactly the two sanctioned FLEET rulesets are applied — and NOT the
  # release-channel-tags org tag standard (applied by name only, never in fleet mode).
  [[ "$output" == *"pr-quality"* ]]
  [[ "$output" == *"code-quality"* ]]
  [[ "$output" != *"release-channel-tags"* ]]
  [[ "$output" == *"done (2 ruleset(s))"* ]]

  # (4/5) the standard label set.
  [[ "$output" == *"needs-human-review"* ]]
  [[ "$output" == *"ack-test-deletion"* ]]
  # ...and the derived persona opt-out family, from the stubbed manifest.
  [[ "$output" == *"dev-lead:hands-off"* ]]

  # (5/6) CODEOWNERS team verification.
  [[ "$output" == *"CODEOWNERS"* ]]
  [[ "$output" == *"org-leads"* ]]

  # (6/6) .gitignore secrets baseline — the marker-wrapped L1 block is seeded.
  [[ "$output" == *".gitignore"* ]]
  [[ "$output" == *">>> BEGIN combsmith secrets baseline"* ]]
  [[ "$output" == *"<<< END combsmith secrets baseline"* ]]

  # PASS summary + the no-drift invariant: a pure DRY_RUN makes no write API calls.
  [[ "$output" == *"PASS"* ]]
  [ ! -f "$CALLS" ]
}

# ── .gitignore secrets baseline seeding (#798) ────────────────────────────────
# A fresh repo must auto-onboard the org secrets baseline. In DRY_RUN the step
# prints the marker-wrapped L1 block (so the intent is auditable) and makes no
# write API calls.
@test "gitignore: DRY_RUN seeds the marker-wrapped baseline with no write calls" {
  # Stub the network-bound sub-scripts so the run reaches the gitignore step; the
  # DRY_RUN gitignore step itself makes no gh calls, so $CALLS stays empty.
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  run env DRY_RUN=true CANARY_RINGS="$RING_SOT" bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *".gitignore"* ]]
  [[ "$output" == *">>> BEGIN combsmith secrets baseline"* ]]
  [[ "$output" == *"<<< END combsmith secrets baseline"* ]]
  # STORY3 anchors ride inside the seeded block.
  [[ "$output" == *"*.pem"* ]]
  [[ "$output" == *"*.key"* ]]
  # The DRY_RUN gitignore step makes no gh write calls (the only $CALLS entries are
  # the stubbed sub-scripts' own "called" lines, never a PUT/POST/PATCH).
  ! grep -qE '(--method (PUT|POST))|PATCH|-X PUT' "$CALLS"
}

@test "gitignore: missing canonical baseline fails the step" {
  _stub_gh
  _stub_substeps 0 0
  _ring_sot_copy
  run env GITIGNORE_CANONICAL="$STUB_DIR/does-not-exist.gitignore" \
    bash "$BOOTSTRAP" owner/new-repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ── worldchest#1: never open a PR that drops per-repo L2 ─────────────────────
# On macOS the lib's L2 pass used to die under BSD awk and return an EMPTY L2, so
# the bootstrap opened combsmith/worldchest#1 — a PR deleting the template's whole
# L2 section while its body said L2 was preserved. The lib is fixed (see
# test/scripts/lib/gitignore-baseline.bats); these pin the bootstrap-side guard:
# if the upserted content lost any L2 line that is not part of the block, the step
# aborts with ::error and makes NO write call.

# _stub_gh_with_gitignore <file> — a gh stub whose contents/.gitignore read returns
# <file> base64-encoded (the real step pipes the stub's output straight into
# base64 -d, so the stub must print the raw encoded string) and which logs every
# write (branch create, file PUT, pr create) to $CALLS.
_stub_gh_with_gitignore() {
  local file="$1" b64
  b64="$(base64 < "$file" | tr -d '\n')"
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"contents/.gitignore"*"--jq"*) echo "$b64" ;;
  *"--method POST"*|*"--method PUT"*|*"PATCH"*|*"pr create"*)
    echo "\$args" >> "$CALLS"
    echo '{"full_name":"stub/repo"}'
    ;;
  *) echo '{"full_name":"stub/repo"}' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# _markered_gitignore <path> — the real canonical block + a template-style L2.
_markered_gitignore() {
  bash -c 'source "$1"; gib_extract_baseline_block "$2"' _ \
    "$SCRIPT_DIR/scripts/lib/gitignore-baseline.sh" "$SCRIPT_DIR/.gitignore" > "$1"
  printf '#\n# L2 — per-repo\n\n# OS / editor\n.DS_Store\n\n# Dependencies / build output\nnode_modules/\ndist/\n\n# Logs\n*.log\n' >> "$1"
}

@test "gitignore guard: an upsert that drops L2 aborts with ::error and opens no PR (worldchest#1)" {
  _markered_gitignore "$STUB_DIR/existing.gitignore"
  _stub_gh_with_gitignore "$STUB_DIR/existing.gitignore"
  # Simulate the pre-fix lib failure mode: upsert returns the block alone, L2 gone.
  run bash -c '
    source "$1"
    upsert_gitignore_baseline() { cat "$1"; }
    step_gitignore owner/new-repo
  ' _ "$BOOTSTRAP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"would drop"* ]]
  [[ "$output" == *"node_modules/"* ]]
  [[ "$output" == *"*.log"* ]]
  # No branch, no file write, no PR.
  [ ! -f "$CALLS" ] || ! grep -qE -- '--method (PUT|POST)|pr create' "$CALLS"
}

@test "gitignore guard: an already-current markered file with L2 is a no-op (no write calls)" {
  _markered_gitignore "$STUB_DIR/existing.gitignore"
  _stub_gh_with_gitignore "$STUB_DIR/existing.gitignore"
  run bash -c 'source "$1"; step_gitignore owner/new-repo' _ "$BOOTSTRAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already carries the current baseline"* ]]
  [ ! -f "$CALLS" ] || ! grep -qE -- '--method (PUT|POST)|pr create' "$CALLS"
}

@test "gitignore guard: legitimate dedup of block lines in L2 is NOT flagged as loss" {
  # An L2 that re-states block lines (a bare *.pem, the block's own section
  # comment) is folded away by the lib on purpose; only genuine per-repo lines count.
  run bash -c '
    source "$1"
    block="$(gib_extract_baseline_block "$2")"
    existing="$(printf "%s\n%s\n" "$block" "*.pem
# combsmith baseline .gitignore — SECRETS ONLY
node_modules/")"
    upserted="$(printf "%s\n%s\n" "$block" "node_modules/")"
    lost="$(_gitignore_l2_lost "$existing" "$upserted" "$block")"
    [ -z "$lost" ] && echo NO-LOSS
    # …but a genuine per-repo line that vanished IS reported.
    upserted2="$(printf "%s\n" "$block")"
    _gitignore_l2_lost "$existing" "$upserted2" "$block"
  ' _ "$BOOTSTRAP" "$SCRIPT_DIR/.gitignore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO-LOSS"* ]]
  [[ "$output" == *"node_modules/"* ]]
  [[ "$output" != *"*.pem"* ]]
}

# ── #1403: the L2-loss guard is a single pass, not a pipeline per line ────────
# The old guard spawned `printf | grep` pipelines for every existing L2 line
# (quadratic, thousands of subprocesses); under pipefail an early-exiting
# `grep -q` could also SIGPIPE the printf and misreport a present line as lost.

@test "gitignore guard (#1403): thousands of distinct L2 lines, no loss — empty and fast" {
  run bash -c '
    source "$1"
    block="$(gib_extract_baseline_block "$2")"
    l2="$(awk "BEGIN { for (i = 0; i < 5000; i++) print \"pat-\" i }")"
    existing="$(printf "%s\n%s\n" "$block" "$l2")"
    start=$SECONDS
    lost="$(_gitignore_l2_lost "$existing" "$existing" "$block")"
    printf "lost=[%s] secs=%s\n" "$lost" "$((SECONDS - start))"
  ' _ "$BOOTSTRAP" "$SCRIPT_DIR/.gitignore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lost=[]"* ]]
  secs="${output##*secs=}"
  [ "$secs" -le 3 ]
}

@test "gitignore guard (#1403): exact semantics — order, duplicates, metachars, whitespace, CRLF" {
  run bash -c '
    source "$1"
    tab="$(printf "\t")"
    block="$(printf "%s\n" "# BEGIN" "*.pem" ".env" "# END")"
    # Unmarkered existing => the whole file is L2. CRLF line endings.
    existing="$(printf "%s\r\n" "keep-me" "gone-1" "*.log" "[abc]" "-dash" "\\#esc" \
      "*.pem  " "gone-1" ".env${tab}" "trail  " "gone-2")"
    upserted="$(printf "%s\n" "keep-me" "*.log" "[abc]" "-dash" "\\#esc" "trail  ")"
    _gitignore_l2_lost "$existing" "$upserted" "$block"
    echo "rc=$?"
  ' _ "$BOOTSTRAP"
  [ "$status" -eq 0 ]
  # Lost = absent from the upserted L2 and (rstripped) not a block line; input
  # order and duplicates kept; CR stripped; "*.pem  " / ".env<TAB>" fold into
  # block lines; "trail  " matches the upserted line exactly.
  [ "$output" = "$(printf "%s\n" gone-1 gone-1 gone-2 rc=0)" ]
}

@test "gitignore guard (#1403): an awk failure in the comparison fails closed, not open" {
  local real
  real="$(command -v awk)"
  # Fail only the comparison pass (it reads its inputs from /dev/fd/* streams).
  cat > "$STUB_BIN/awk" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in /dev/fd/*|/proc/*) echo "awk: simulated failure" >&2; exit 2 ;; esac; done
exec "$real" "\$@"
SHIM
  chmod +x "$STUB_BIN/awk"
  run bash -c '
    source "$1"
    if lost="$(_gitignore_l2_lost "$(printf "a\nb\n")" "$(printf "a\nb\n")" "# x")"; then
      echo "PASSED-OPEN lost=[$lost]"
    else
      echo "FAILED-CLOSED"
    fi
  ' _ "$BOOTSTRAP"
  [[ "$output" == *"FAILED-CLOSED"* ]]
}
