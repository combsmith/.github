#!/usr/bin/env bats
# Issue #1125 — pr-review.yml is deployable in REPLACE-IF-PRESENT mode.
#
# Every fleet pr-review caller pinned the legacy bare `@pr-review/stable` and had
# no template, so the sweep never re-pinned it and no pr-review release could
# reach the fleet. The sweep now owns the EXISTING callers only:
#   - it never targets petry-projects/.github-private, whose pr-review.yml is the
#     ENGINE (the reusable itself), not a caller;
#   - it never seeds the file into a repo that has no caller today;
#   - an existing caller is replaced with the template body, with BOTH pin lines
#     (`uses:` and `agent_ref:`) on the repo's ring-tier channel;
#   - compliance compares the whole body (rendered at the tier channel), so a
#     caller with the right pin but a leftover `concurrency:` block is drift;
#   - a second run over a replaced caller is a no-op.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  TEMPLATE="${REPO_ROOT}/standards/workflows/pr-review.yml"
  GH_LOG="${TT_TMP}/gh.log"; export GH_LOG
  export GH_MATCHING_REFS="refs/tags/pr-review/v1-stable
refs/tags/pr-review/v1-next
refs/tags/pr-review/v1-ring0
refs/tags/pr-review/v1-ring1
refs/tags/pr-review/v1.29.0"
}

teardown() { rm -rf "$TT_TMP"; }

b64() { base64 -w 0 2>/dev/null || base64 -b 0; }

# Fake gh (every call is appended to $GH_LOG):
#   GH_MATCHING_REFS  channel/release tags served for matching-refs.
#   GH_CONTENT_B64    base64 of .github/workflows/pr-review.yml (unset → 404 = absent).
#   agent-ingress.yml always 404s (not collapsed); tag probes and repo reads succeed.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *matching-refs/tags/*)
      [ -n "${GH_MATCHING_REFS:-}" ] && printf '%s\n' "${GH_MATCHING_REFS}"
      exit 0 ;;
    *contents/.github/workflows/agent-ingress.yml)
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    *contents*)
      if [ -n "${GH_CONTENT_B64:-}" ]; then
        printf '{"sha":"abc123","content":"%s"}' "$GH_CONTENT_B64"; exit 0
      fi
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# The template rendered at <channel> — what a correctly deployed caller looks like:
# only the two pin lines move; the header prose keeps the template's channel.
rendered_at() {  # <channel>
  sed -E "/^[[:space:]]*(uses|agent_ref):/s#pr-review/v1-stable#$1#" "$TEMPLATE"
}

# The legacy fleet caller shape (TalkTerm-like): bare pr-review/stable pin, an
# `opened` trigger and a stub-level concurrency block.
legacy_caller() {
  cat <<'YAML'
name: PR Review Agent

on:
  pull_request:
    types: [opened, ready_for_review, reopened, synchronize]
  check_suite:
    types: [completed]

permissions:
  contents: read
  pull-requests: write
  checks: read

concurrency:
  group: pr-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/stable
    with:
      agent_ref: pr-review/stable
    secrets: inherit
YAML
}

# ── template ────────────────────────────────────────────────────────────────

@test "template exists, keeps name/job id, and pins uses: and agent_ref: on the same channel" {
  [ -f "$TEMPLATE" ]
  grep -qE '^name: PR Review Agent$' "$TEMPLATE"
  grep -qE '^  review:$' "$TEMPLATE"
  grep -qF 'SOURCE OF TRUTH: petry-projects/.github/standards/workflows/pr-review.yml' "$TEMPLATE"
  grep -qF 'AGENTS — READ BEFORE EDITING' "$TEMPLATE"
  grep -qF 'uses: petry-projects/.github-private/.github/workflows/pr-review.yml@pr-review/v1-stable  # NOSONAR(githubactions:S7637)' "$TEMPLATE"
  grep -qE '^      agent_ref: pr-review/v1-stable$' "$TEMPLATE"
  grep -qF "if: \${{ github.actor != 'dependabot[bot]' }}" "$TEMPLATE"
  run grep -qE '^concurrency:' "$TEMPLATE"
  [ "$status" -eq 1 ]
}

@test "pr-review.yml is deployable and in replace-if-present mode" {
  run bash -c 'source "$1"; is_deployable_workflow pr-review.yml && is_replace_if_present_workflow pr-review.yml' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── guard 1: never target the engine host ───────────────────────────────────

@test "guard: petry-projects/.github-private is never targeted, even with --force" {
  GH_CONTENT_B64="$(printf 'name: PR Review Agent\non:\n  workflow_call:\n' | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --force --repo .github-private --workflow pr-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '.github-private/pr-review.yml (engine host'
  [[ "$output" != *"Would open PR"* ]]
  # The engine file is never even read.
  touch "$GH_LOG"
  run grep -qF 'contents/.github/workflows/pr-review.yml' "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "guard: the engine-host check matches only pr-review.yml on .github-private" {
  run bash -c 'source "$1"; is_engine_host_target pr-review.yml .github-private' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; is_engine_host_target pr-review.yml TalkTerm' _ "$SCRIPT"
  [ "$status" -eq 1 ]
  run bash -c 'source "$1"; is_engine_host_target pr-auto-review.yml .github-private' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

# ── guard 2: never seed a repo that has no caller ───────────────────────────

@test "guard: a repo with no pr-review.yml is never seeded, even with --force" {
  install_gh_stub   # no GH_CONTENT_B64 → 404 → no caller
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --force --repo incubator --workflow pr-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'incubator/pr-review.yml (replace-if-present: no existing caller'
  [[ "$output" != *"Would open PR"* ]]
}

@test "guard: a full sweep of a repo with no caller never lists pr-review.yml" {
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo incubator
  [ "$status" -eq 0 ]
  local pr_line
  pr_line="$(echo "$output" | grep -F 'Would open PR for incubator')"
  [[ "$pr_line" != *" pr-review.yml"* ]]
  [[ "$pr_line" != *",pr-review.yml"* ]]
}

# ── existing callers are replaced, pinned to their tier ─────────────────────

@test "replace: a ring1 caller on bare pr-review/stable is replaced at @pr-review/v1-ring1" {
  GH_CONTENT_B64="$(legacy_caller | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow pr-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'TalkTerm/pr-review.yml would pin @pr-review/v1-ring1'
  echo "$output" | grep -qF 'TalkTerm/pr-review.yml replace-if-present: replacing existing caller with the template body'
  echo "$output" | grep -qE 'Would open PR for TalkTerm .* pr-review.yml'
}

@test "replace: a stable-tier caller on bare pr-review/stable is replaced at @pr-review/v1-stable" {
  GH_CONTENT_B64="$(legacy_caller | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo broodly --workflow pr-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'broodly/pr-review.yml would pin @pr-review/v1-stable'
  echo "$output" | grep -qE 'Would open PR for broodly .* pr-review.yml'
}

@test "drift: right pin but a leftover concurrency: block is replaced" {
  # Template body at the right tier channel, plus a stub-level concurrency block.
  GH_CONTENT_B64="$( { rendered_at pr-review/v1-ring1 | sed '/^permissions: {}$/a\
\
concurrency:\
  group: pr-review-${{ github.ref }}\
  cancel-in-progress: true'; } | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow pr-review.yml
  [ "$status" -eq 0 ]
  [[ "$output" != *"already compliant"* ]]
  echo "$output" | grep -qE 'Would open PR for TalkTerm .* pr-review.yml'
}

@test "drift: the template body on the bare pr-review/stable pin is drift" {
  GH_CONTENT_B64="$(rendered_at pr-review/stable | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo broodly --workflow pr-review.yml
  [ "$status" -eq 0 ]
  [[ "$output" != *"already compliant"* ]]
  echo "$output" | grep -qE 'Would open PR for broodly .* pr-review.yml'
}

@test "drift: the right body pinned to the wrong tier channel is drift" {
  # TalkTerm is ring1; a v1-stable pin is not its tier channel.
  GH_CONTENT_B64="$(rendered_at pr-review/v1-stable | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow pr-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'TalkTerm/pr-review.yml would pin @pr-review/v1-ring1'
}

# ── the deployed content (non-dry run, PR primitive captured) ───────────────

# deploy_capture <repo> — run deploy_repo for pr-review.yml with DRY_RUN=false and
# the PR primitive replaced by a stub that copies each deployed file to $TT_TMP/out.
deploy_capture() {
  bash -c '
    source "$1"
    set +e
    ORG=petry-projects; DRY_RUN=false; FORCE=false; _OVERALL_FAILED=0
    WORKFLOWS=(pr-review.yml)
    sd_deploy_files_via_pr() {
      shift 5
      mkdir -p "$OUT"
      while [ "$#" -ge 2 ]; do cp "$2" "$OUT/${1##*/}"; shift 2; done
      echo "OPENED #1"
    }
    deploy_repo "$2"
  ' _ "$SCRIPT" "$1"
}

@test "deploy: the replaced caller is the template body with both pin lines on the tier channel" {
  GH_CONTENT_B64="$(legacy_caller | b64)"; export GH_CONTENT_B64
  install_gh_stub
  export OUT="${TT_TMP}/out"
  GH_TOKEN=x run deploy_capture TalkTerm
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'TalkTerm — opened #1'
  [ -f "$OUT/pr-review.yml" ]
  diff <(rendered_at pr-review/v1-ring1) "$OUT/pr-review.yml"
  grep -qF 'workflows/pr-review.yml@pr-review/v1-ring1  # NOSONAR(githubactions:S7637)' "$OUT/pr-review.yml"
  grep -qE '^      agent_ref: pr-review/v1-ring1$' "$OUT/pr-review.yml"
  run grep -qE '^ +(uses:.*@|agent_ref: )pr-review/v1-stable' "$OUT/pr-review.yml"
  [ "$status" -eq 1 ]
  run grep -qE '^concurrency:' "$OUT/pr-review.yml"
  [ "$status" -eq 1 ]
}

@test "deploy: a second run over the replaced caller is a no-op" {
  GH_CONTENT_B64="$(legacy_caller | b64)"; export GH_CONTENT_B64
  install_gh_stub
  export OUT="${TT_TMP}/out"
  GH_TOKEN=x run deploy_capture TalkTerm
  [ "$status" -eq 0 ]
  [ -f "$OUT/pr-review.yml" ]
  # Second run: the repo now carries exactly what the first run deployed.
  GH_CONTENT_B64="$(b64 < "$OUT/pr-review.yml")"; export GH_CONTENT_B64
  rm -rf "$OUT"
  GH_TOKEN=x run deploy_capture TalkTerm
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'TalkTerm/.github/workflows/pr-review.yml already compliant'
  [ ! -e "$OUT" ]
}

@test "no-op: a stable-tier repo carrying the template verbatim is already compliant" {
  GH_CONTENT_B64="$(b64 < "$TEMPLATE")"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo broodly --workflow pr-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'already compliant'
  [[ "$output" != *"Would open PR"* ]]
}
