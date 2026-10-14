#!/usr/bin/env bats
# Unit tests for scripts/lib/ring-pins.sh — the canary-ring pin model shared by
# compliance-audit.sh (check_centralized_workflow_stubs) and
# deploy-standard-workflows.sh (is_already_compliant). The lib has no `main`, so
# it is sourced directly and its pure helpers are exercised in-process.

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/ring-pins.sh"
}

@test "ring_tier_for_repo maps each tier" {
  [ "$(ring_tier_for_repo .github-private)" = "next" ]
  [ "$(ring_tier_for_repo .github)" = "ring0" ]
  [ "$(ring_tier_for_repo TalkTerm)" = "ring1" ]
  [ "$(ring_tier_for_repo bmad-bgreat-suite)" = "ring1" ]
  [ "$(ring_tier_for_repo markets)" = "stable" ]
  [ "$(ring_tier_for_repo anything-else)" = "stable" ]
}

@test "ring_is_ring_reusable recognises the ring set (incl. dev-lead)" {
  ring_is_ring_reusable auto-rebase
  ring_is_ring_reusable pr-review-mention
  ring_is_ring_reusable dev-lead
  # channel-ified in #606 (Story B of the shim-identity epic #604)
  ring_is_ring_reusable feature-ideation
  ring_is_ring_reusable pr-auto-review
  ! ring_is_ring_reusable add-to-project
}

@test "ring_canonical_ref: feature-ideation and pr-auto-review resolve to tier channels (#606)" {
  [ "$(ring_canonical_ref feature-ideation markets)" = "feature-ideation/stable" ]
  [ "$(ring_canonical_ref feature-ideation TalkTerm)" = "feature-ideation/ring1" ]
  [ "$(ring_canonical_ref pr-auto-review markets)" = "pr-auto-review/stable" ]
  [ "$(ring_canonical_ref pr-auto-review TalkTerm)" = "pr-auto-review/ring1" ]
}

@test "ring_canonical_ref is the repo's tier channel" {
  [ "$(ring_canonical_ref agent-shield TalkTerm)" = "agent-shield/ring1" ]
  [ "$(ring_canonical_ref agent-shield markets)" = "agent-shield/stable" ]
  [ "$(ring_canonical_ref dev-lead .github-private)" = "dev-lead/next" ]
}

@test "ring_canonical_ref: major-aware form yields <agent>/v<major>-<tier> (#657 F3)" {
  # A major argument opts the ref into the major-scoped channel line; the tier
  # is still the repo's ring tier.
  [ "$(ring_canonical_ref agent-shield markets 2)" = "agent-shield/v2-stable" ]
  [ "$(ring_canonical_ref agent-shield TalkTerm 2)" = "agent-shield/v2-ring1" ]
  [ "$(ring_canonical_ref dev-lead .github-private 5)" = "dev-lead/v5-next" ]
  # No major argument is backward-compatible: the legacy bare-tier ref.
  [ "$(ring_canonical_ref agent-shield markets)" = "agent-shield/stable" ]
}

@test "ring_pinned_major: extracts M from v<M>-<tier>, empty for bare tier (#657 F3)" {
  [ "$(ring_pinned_major agent-shield/v3-stable)" = "3" ]
  [ "$(ring_pinned_major agent-shield/v12-ring1)" = "12" ]
  # Bare-tier (legacy/unmajored) refs carry no major.
  [ -z "$(ring_pinned_major agent-shield/stable)" ]
  [ -z "$(ring_pinned_major agent-shield/ring0)" ]
}

@test "ring_accepted_refs: canonical first, then the ring-channel grace" {
  run ring_accepted_refs auto-rebase TalkTerm
  [ "${lines[0]}" = "auto-rebase/ring1" ]                 # canonical = tier channel
  printf '%s\n' "${lines[@]}" | grep -qx "auto-rebase/stable"  # higher tier accepted
  # the pre-ring @v1/@v2 grace was dropped in #870 — migration complete
  ! printf '%s\n' "${lines[@]}" | grep -qx "v1"
  ! printf '%s\n' "${lines[@]}" | grep -qx "v2"
}

@test "ring_legacy_csv excludes the canonical and comma-joins the ring channels" {
  run ring_legacy_csv auto-rebase markets
  [[ "$output" == *"auto-rebase/next"* ]]
  [[ "$output" == *"auto-rebase/ring1"* ]]
  [[ "$output" != *"auto-rebase/stable"* ]]
  # no pre-ring grace
  [[ "$output" != *"v1"* ]]
  [[ "$output" != *"v2"* ]]
}

# ══ major-scoped channels tooling: F5 shared helpers (epic #657) ═══════════════

@test "ring_highest_major: picks the MAJOR of the highest strict semver" {
  [ "$(ring_highest_major 1.2.3 2.0.1 1.9.9)" = "2" ]
  [ "$(ring_highest_major 10.0.0 9.9.9)" = "10" ]
  # tolerate a leading v on the token
  [ "$(ring_highest_major v3.1.0 v2.9.9)" = "3" ]
}

@test "ring_highest_major: ignores non-semver tokens; empty when none valid" {
  [ "$(ring_highest_major 2.0.0 not-a-version 1.0.0)" = "2" ]
  [ -z "$(ring_highest_major)" ]
  [ -z "$(ring_highest_major 2-next latest '')" ]
}

# ── channel major (#870): the CALLER-CONTRACT major, not the release major ──────

@test "ring_highest_channel_major: picks the highest v<M>-<tier> channel token" {
  # channel tokens are `<M>-<tier>` (the `v` prefix is already stripped by the
  # caller, mirroring ring_host_current_channel_major's sed).
  [ "$(ring_highest_channel_major 1-stable 1-ring1 1-next)" = "1" ]
  [ "$(ring_highest_channel_major 2-stable 3-ring0 2-ring1)" = "3" ]
  [ "$(ring_highest_channel_major 10-stable 9-ring1)" = "10" ]
}

@test "ring_highest_channel_major: ignores RELEASE semver; empty when no channel token (#870)" {
  # The dev-lead regression: a high release major (14.0.0) must NOT be picked up —
  # only the channel tokens count, so v1 is the caller-contract major.
  [ "$(ring_highest_channel_major 14.0.0 1-stable 1-ring1)" = "1" ]
  # release-only input (no channel token) yields empty → callers fall back to bare.
  [ -z "$(ring_highest_channel_major 14.0.0 13.9.9)" ]
  [ -z "$(ring_highest_channel_major)" ]
  # a bare tier (no v<M>- major) is not a channel-major token.
  [ -z "$(ring_highest_channel_major stable ring1)" ]
}

@test "ring_repin_uses: rewrites the reusable uses: ref, preserving the trailing comment" {
  local stub="jobs:
  auto-rebase:
    uses: combsmith/.github/.github/workflows/auto-rebase-reusable.yml@auto-rebase/stable  # NOSONAR keep
    secrets: inherit"
  run bash -c 'source "'"$REPO_ROOT"'/scripts/lib/ring-pins.sh"; ring_repin_uses auto-rebase auto-rebase/v2-stable <<<"$1"' _ "$stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-rebase-reusable.yml@auto-rebase/v2-stable  # NOSONAR keep"* ]]
  [[ "$output" != *"@auto-rebase/stable "* ]]
}

@test "ring_repin_uses: also rewrites a matching agent_ref (dev-lead stub)" {
  local stub="    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable
    with:
      agent_ref: dev-lead/stable"
  run bash -c 'source "'"$REPO_ROOT"'/scripts/lib/ring-pins.sh"; ring_repin_uses dev-lead dev-lead/v4-ring1 <<<"$1"' _ "$stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead-reusable.yml@dev-lead/v4-ring1"* ]]
  [[ "$output" == *"agent_ref: dev-lead/v4-ring1"* ]]
}

@test "ring_vform_tier_aligned: true only for the repo's tier v-form (any major)" {
  ring_vform_tier_aligned auto-rebase/v2-ring1 auto-rebase TalkTerm    # ring1 repo
  ring_vform_tier_aligned auto-rebase/v9-stable auto-rebase markets    # stable repo
  # wrong tier for the repo → not aligned
  ! ring_vform_tier_aligned auto-rebase/v2-ring0 auto-rebase TalkTerm
  # bare tier (no v<M>-) → not a v-form
  ! ring_vform_tier_aligned auto-rebase/ring1 auto-rebase TalkTerm
}

# ── meta-repo self-host vs channel-consumer discrimination (#704) ──────────────

@test "ring_stub_selfhosts: true for a local ./ self-host ref" {
  # .github hosts agent-shield's reusable itself, so its own stub uses a local ref.
  local stub="jobs:
  agent-shield:
    uses: ./.github/workflows/agent-shield-reusable.yml  # local ref — always current
    secrets: inherit"
  run ring_stub_selfhosts agent-shield <<< "$stub"
  [ "$status" -eq 0 ]
}

@test "ring_stub_selfhosts: false for a channel-pinned consumer ref" {
  # .github does NOT host dev-lead (it lives in .github-private) — its stub is a
  # channel consumer, so it must be re-pinned, not treated as self-host.
  local stub="jobs:
  dev-lead:
    uses: combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring0
    with:
      agent_ref: dev-lead/ring0"
  run ring_stub_selfhosts dev-lead <<< "$stub"
  [ "$status" -ne 0 ]
}

@test "ring_stub_selfhosts: false when the stub does not reference the reusable at all" {
  local stub="jobs:
  something-else:
    uses: ./.github/workflows/other-reusable.yml"
  run ring_stub_selfhosts dev-lead <<< "$stub"
  [ "$status" -ne 0 ]
}

# ── gh-backed channel-major / tag-existence helpers (#870) ──────────────────────
# These read the host repo's tags via `gh api`, so a fake gh is put on PATH. It
# serves matching-refs (already `--jq '.[]?.ref'`-projected, one ref per line) and
# single-ref existence probes.

_install_gh_stub() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *git/ref/tags/*)
      tag="${2##*/git/ref/tags/}"
      printf '%s\n' "${GH_EXISTING_TAGS:-}" | grep -qxF "$tag" && exit 0
      printf 'Not Found\n' >&2
      exit 1 ;;
    *matching-refs/tags/*)
      [ -n "${GH_MATCHING_REFS:-}" ] && printf '%s\n' "${GH_MATCHING_REFS}"
      exit 0 ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

@test "ring_host_current_channel_major: picks v1 for dev-lead despite a v14 release tag (#870)" {
  export GH_MATCHING_REFS="refs/tags/dev-lead/v14.0.0
refs/tags/dev-lead/v1-stable
refs/tags/dev-lead/v1-next
refs/tags/dev-lead/v1-ring0
refs/tags/dev-lead/v1-ring1"
  _install_gh_stub
  [ "$(ring_host_current_channel_major combsmith/.github-private dev-lead)" = "1" ]
}

@test "ring_host_current_channel_major: empty when only release tags exist (#870)" {
  export GH_MATCHING_REFS="refs/tags/auto-rebase/v2.3.1
refs/tags/auto-rebase/v1.0.0"
  _install_gh_stub
  [ -z "$(ring_host_current_channel_major combsmith/.github auto-rebase)" ]
}

@test "ring_tag_exists: true only for a ref present on the host (#870)" {
  export GH_EXISTING_TAGS="dev-lead/v1-ring1
dev-lead/v1-stable"
  _install_gh_stub
  run ring_tag_exists combsmith/.github-private dev-lead/v1-ring1
  [ "$status" -eq 0 ]
  run ring_tag_exists combsmith/.github-private dev-lead/v1-ring0
  [ "$status" -ne 0 ]
}
