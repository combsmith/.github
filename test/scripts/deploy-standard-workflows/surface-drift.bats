#!/usr/bin/env bats
# #1236: the deploy sweep's drift check (is_already_compliant) must agree with the
# compliance audit's caller-stub surface-drift guard (check_stub_surface_drift).
#
# The audit flags a stub whose `on:` / `permissions:` / `concurrency:` surface
# differs from the canonical template (stub-surface-drift-<wf>-<surface>). But the
# sweep only checked the channel pin and the S7635 marker, so a pin-correct stub
# missing e.g. the `merge_group:` trigger or the `concurrency:` block was logged
# "already compliant" and NEVER re-synced — the audit re-flagged it every cycle
# (TalkTerm / broodly / markets / ContentTwin / google-app-scripts, #1185 → #1236).
#
# All runs are --dry-run against a single --repo/--workflow with a fake `gh`.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  STANDARDS="${REPO_ROOT}/standards/workflows"
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh: matching-refs returns GH_MATCHING_REFS, contents returns GH_CONTENT_B64
# (unset → 404), every single-ref existence probe resolves.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *git/ref/tags/*) exit 0 ;;
    *matching-refs/tags/*)
      [ -n "${GH_MATCHING_REFS:-}" ] && printf '%s\n' "${GH_MATCHING_REFS}"
      exit 0 ;;
    *contents*)
      if [ -n "${GH_CONTENT_B64:-}" ]; then
        printf '{"sha":"abc123","content":"%s"}' "$GH_CONTENT_B64"
        exit 0
      fi
      exit 1 ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

b64() { base64 -w 0 2>/dev/null || base64 -b 0; }

# deployed <workflow> <agent> <ref> → the canonical template re-pinned to <ref> on
# stdout; callers pipe it through a mutation to model a drifted stub.
deployed() {
  sed -E "s|(${2}-reusable\.yml)@[^[:space:]]+|\1@${3}|" "${STANDARDS}/$1"
}

@test "#1236: a tier-correct stub matching the template surfaces stays compliant (no churn)" {
  export GH_MATCHING_REFS="refs/tags/agent-shield/v2-stable"
  GH_CONTENT_B64="$(deployed agent-shield.yml agent-shield agent-shield/v2-stable | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow agent-shield.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}

@test "#1236: a pin-correct stub MISSING the merge_group trigger is drift (on: surface)" {
  export GH_MATCHING_REFS="refs/tags/agent-shield/v2-stable"
  GH_CONTENT_B64="$(deployed agent-shield.yml agent-shield agent-shield/v2-stable \
    | grep -vE '^[[:space:]]+merge_group:' | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow agent-shield.yml
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'already compliant'
  echo "$output" | grep -qE 'Would open PR for markets .* agent-shield.yml'
}

@test "#1236: dependency-audit stub missing merge_group is drift (on: surface)" {
  export GH_MATCHING_REFS="refs/tags/dependency-audit/v2-ring1"
  GH_CONTENT_B64="$(deployed dependency-audit.yml dependency-audit dependency-audit/v2-ring1 \
    | grep -vE '^[[:space:]]+merge_group:' | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow dependency-audit.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for TalkTerm .* dependency-audit.yml'
}

@test "#1236: a pin-correct stub MISSING the concurrency block is drift (concurrency: surface)" {
  export GH_MATCHING_REFS="refs/tags/auto-rebase/v2-stable"
  # Drop the top-level `concurrency:` key and its indented body.
  GH_CONTENT_B64="$(deployed auto-rebase.yml auto-rebase auto-rebase/v2-stable \
    | awk '/^concurrency:/{skip=1; next} skip && /^[[:space:]]+/{next} {skip=0; print}' \
    | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'already compliant'
  echo "$output" | grep -qE 'Would open PR for markets .* auto-rebase.yml'
}

@test "#1236: a stub whose permissions drifted is drift (permissions: surface)" {
  export GH_MATCHING_REFS="refs/tags/agent-shield/v2-stable"
  GH_CONTENT_B64="$(deployed agent-shield.yml agent-shield agent-shield/v2-stable \
    | sed -E 's/^([[:space:]]+contents:[[:space:]]*)read/\1write/' | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow agent-shield.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for markets .* agent-shield.yml'
}

@test "#1236: a stub differing only by a documented per-repo with: input stays compliant" {
  # agent-shield documents `with:` inputs as repo-adjustable; surfaces are unchanged.
  export GH_MATCHING_REFS="refs/tags/agent-shield/v2-stable"
  GH_CONTENT_B64="$( { deployed agent-shield.yml agent-shield agent-shield/v2-stable; \
    printf '    with:\n      min-severity: high\n'; } | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow agent-shield.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
}

@test "#1236: surface drift is NOT applied to a meta-repo consumer stub (re-pinned in place)" {
  # .github re-pins its OWN dev-lead consumer body in place, so a redeploy could never
  # fix a surface difference — counting it would loop forever (cf. #878). The audit
  # likewise exempts .github from the surface check.
  export GH_MATCHING_REFS="refs/tags/dev-lead/v1-ring0"
  local body="on:
  workflow_dispatch:
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-ring0
    with:
      agent_ref: dev-lead/v1-ring0
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable"
  GH_CONTENT_B64="$(printf '%s\n' "$body" | b64)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo .github --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
}
