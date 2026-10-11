#!/usr/bin/env bats
# Issue #1285 — the sweep compares the WHOLE stub body for petry-projects/repo-template.
#
# For a ring-managed stub the sweep's compliance rule is pin-only (plus the S7635
# marker), so a stub whose body differs from the template read as `already
# compliant` — while .github-private's template_stub_drift.sh byte-compares
# repo-template against the standards channel and fails on the same file. For
# repo-template only (option 1), compliance now also requires the body to equal
# the template rendered at the repo's tier channel (stub_body_matches_template):
#   - a pin-correct stub with a stale body is drift and is re-synced;
#   - the template verbatim is still compliant (no churn);
#   - every other repo keeps the pin-only rule;
#   - a BODY_PRESERVING_WORKFLOWS stub (feature-ideation.yml) is never overwritten
#     because of a body difference;
#   - the re-synced body keeps the repo's ring tier pin.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  TEMPLATE="${REPO_ROOT}/standards/workflows/dependabot-rebase.yml"
  FI_TEMPLATE="${REPO_ROOT}/standards/workflows/feature-ideation.yml"
  export GH_MATCHING_REFS="refs/tags/dependabot-rebase/v2-stable
refs/tags/dependabot-rebase/v2-next
refs/tags/dependabot-rebase/v2-ring0
refs/tags/dependabot-rebase/v2-ring1
refs/tags/feature-ideation/v1-stable
refs/tags/feature-ideation/v1-next
refs/tags/feature-ideation/v1-ring0
refs/tags/feature-ideation/v1-ring1"
}

teardown() { rm -rf "$TT_TMP"; }

b64() { base64 -w 0 2>/dev/null || base64 -b 0; }

# Fake gh:
#   GH_MATCHING_REFS  channel tags served for matching-refs (all agents; the
#                     channel-major helper filters by the `<agent>/` prefix).
#   GH_CONTENT_B64    base64 of the existing stub (unset → 404 = absent).
#   agent-ingress.yml always 404s (not collapsed); repo reads succeed.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *matching-refs/tags/*)
      agent="${2##*matching-refs/tags/}"; agent="${agent%%/*}"
      [ -n "${GH_MATCHING_REFS:-}" ] && printf '%s\n' "${GH_MATCHING_REFS}" | grep -F "refs/tags/${agent}/" || true
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

# The template rendered at <channel> — only the reusable pin moves.
rendered_at() {  # <channel>
  sed -E "/^[[:space:]]*uses:/s#dependabot-rebase/v2-stable#$1#" "$TEMPLATE"
}

# The template at <channel> with a stale header comment — the #1075 shape: the
# pin is right, only the body differs.
stale_body_at() {  # <channel>
  rendered_at "$1" | sed 's/^#   • If you need different behaviour, open a PR against the reusable in the$/#   • OLD WORDING — open a PR against the reusable in the/'
}

# A ring registry copy with repo-template moved into dependabot-rebase's ring1.
ring1_registry() {
  local out="${TT_TMP}/canary-rings.json"
  jq '.agents["dependabot-rebase"].rings |= map(if .channel == "ring1" then .members += ["petry-projects/repo-template"] else . end)' \
    "${REPO_ROOT}/standards/canary-rings.json" > "$out"
  printf '%s' "$out"
}

# deploy_capture <repo> <workflow> — run deploy_repo with DRY_RUN=false and the
# PR primitive replaced by a stub that copies each deployed file to $OUT.
deploy_capture() {
  bash -c '
    source "$1"
    set +e
    ORG=petry-projects; DRY_RUN=false; FORCE=false; _OVERALL_FAILED=0
    WORKFLOWS=("$3")
    sd_deploy_files_via_pr() {
      shift 5
      mkdir -p "$OUT"
      while [ "$#" -ge 2 ]; do cp "$2" "$OUT/${1##*/}"; shift 2; done
      echo "OPENED #1"
    }
    deploy_repo "$2"
  ' _ "$SCRIPT" "$1" "$2"
}

@test "fixture: the stale body really differs from the template and keeps the right pin" {
  run diff -q <(stale_body_at dependabot-rebase/v2-stable) "$TEMPLATE"
  [ "$status" -eq 1 ]
  stale_body_at dependabot-rebase/v2-stable | grep -qF 'dependabot-rebase-reusable.yml@dependabot-rebase/v2-stable'
}

# ── repo-template: full-body compare ───────────────────────────────────────

@test "repo-template: a pin-correct stub with a stale body is drift and is re-synced" {
  GH_CONTENT_B64="$(stale_body_at dependabot-rebase/v2-stable | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo repo-template --workflow dependabot-rebase.yml
  [ "$status" -eq 0 ]
  [[ "$output" != *"already compliant"* ]]
  echo "$output" | grep -qF 'repo-template/dependabot-rebase.yml would pin @dependabot-rebase/v2-stable'
  echo "$output" | grep -qE 'Would open PR for repo-template .* dependabot-rebase.yml'
}

@test "repo-template: the template verbatim is already compliant" {
  GH_CONTENT_B64="$(b64 < "$TEMPLATE")"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo repo-template --workflow dependabot-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'repo-template/.github/workflows/dependabot-rebase.yml already compliant'
  [[ "$output" != *"Would open PR"* ]]
}

@test "repo-template: the re-synced stub is the template body, and a second run is a no-op" {
  GH_CONTENT_B64="$(stale_body_at dependabot-rebase/v2-stable | b64)"; export GH_CONTENT_B64
  install_gh_stub
  export OUT="${TT_TMP}/out"
  GH_TOKEN=x run deploy_capture repo-template dependabot-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'repo-template — opened #1'
  diff "$TEMPLATE" "$OUT/dependabot-rebase.yml"
  GH_CONTENT_B64="$(b64 < "$OUT/dependabot-rebase.yml")"; export GH_CONTENT_B64
  rm -rf "$OUT"
  GH_TOKEN=x run deploy_capture repo-template dependabot-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'already compliant'
  [ ! -e "$OUT" ]
}

# ── the repo keeps its ring tier pin when its body is re-synced ─────────────

@test "repo-template on ring1: a stale body is re-synced at its ring1 pin, then compliant" {
  CANARY_RINGS="$(ring1_registry)"; export CANARY_RINGS
  GH_CONTENT_B64="$(stale_body_at dependabot-rebase/v2-ring1 | b64)"; export GH_CONTENT_B64
  install_gh_stub
  export OUT="${TT_TMP}/out"
  GH_TOKEN=x run deploy_capture repo-template dependabot-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'repo-template — opened #1'
  diff <(rendered_at dependabot-rebase/v2-ring1) "$OUT/dependabot-rebase.yml"
  run grep -qE '^ +uses:.*@dependabot-rebase/v2-stable' "$OUT/dependabot-rebase.yml"
  [ "$status" -eq 1 ]
  GH_CONTENT_B64="$(b64 < "$OUT/dependabot-rebase.yml")"; export GH_CONTENT_B64
  rm -rf "$OUT"
  GH_TOKEN=x run deploy_capture repo-template dependabot-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'already compliant'
  [ ! -e "$OUT" ]
}

# ── every other repo keeps the pin-only rule ────────────────────────────────

@test "other repos: a pin-correct stub with a stale body is still already compliant" {
  GH_CONTENT_B64="$(stale_body_at dependabot-rebase/v2-stable | b64)"; export GH_CONTENT_B64
  install_gh_stub
  local r
  for r in broodly markets incubator; do
    run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo "$r" --workflow dependabot-rebase.yml
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$r/.github/workflows/dependabot-rebase.yml already compliant"
    [[ "$output" != *"Would open PR"* ]]
  done
}

@test "the full-body rule matches repo-template by name only, bare or org-qualified" {
  run bash -c 'source "$1"; is_full_body_compare_repo repo-template && is_full_body_compare_repo petry-projects/repo-template' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; is_full_body_compare_repo broodly' _ "$SCRIPT"
  [ "$status" -eq 1 ]
  run bash -c 'source "$1"; is_full_body_compare_repo repo-template-fork' _ "$SCRIPT"
  [ "$status" -eq 1 ]
}

# ── BODY_PRESERVING_WORKFLOWS are never overwritten for a body difference ────

@test "repo-template: a tuned feature-ideation.yml at the right pin is not overwritten" {
  GH_CONTENT_B64="$(sed 's/^jobs:$/# TUNED-REPO-CONTEXT-SENTINEL\njobs:/' "$FI_TEMPLATE" | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run bash -c 'base64 -d <<<"$GH_CONTENT_B64" | grep -qF TUNED-REPO-CONTEXT-SENTINEL'
  [ "$status" -eq 0 ]
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo repo-template --workflow feature-ideation.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'repo-template/.github/workflows/feature-ideation.yml already compliant'
  [[ "$output" != *"Would open PR"* ]]
}

@test "repo-template: a tuned feature-ideation.yml on a stale pin is re-pinned in place, body kept" {
  GH_CONTENT_B64="$(sed -e 's#feature-ideation/v1-stable#feature-ideation/stable#' \
    -e 's/^jobs:$/# TUNED-REPO-CONTEXT-SENTINEL\njobs:/' "$FI_TEMPLATE" | b64)"; export GH_CONTENT_B64
  install_gh_stub
  export OUT="${TT_TMP}/out"
  GH_TOKEN=x run deploy_capture repo-template feature-ideation.yml
  [ "$status" -eq 0 ]
  grep -qF 'TUNED-REPO-CONTEXT-SENTINEL' "$OUT/feature-ideation.yml"
  grep -qF 'feature-ideation-reusable.yml@feature-ideation/v1-stable' "$OUT/feature-ideation.yml"
}
