#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ring-pins.sh — single source of truth for the canary-ring pin model.
#
# The #482 `.github`-hosted reusables (and dev-lead) are released through the
# concentric-ring channels of epic #495: next → ring0 → ring1 → stable. Both
# the compliance audit (`check_centralized_workflow_stubs` in
# compliance-audit.sh) and the deploy sweep (`is_already_compliant` in
# deploy-standard-workflows.sh) must agree on
#   (a) which repo sits in which ring tier, and
#   (b) which `@<channel>` refs are acceptable for a stub in that repo,
# otherwise "drift" (deploy) and "non-compliant" (audit) diverge — the exact
# three-way inconsistency #482 exists to close. This file is sourced by both so
# they can never drift again.
#
# Keep the topology in sync with combsmith/.github-private's
# scripts/cut-release.sh channels and docs/release/.
# ---------------------------------------------------------------------------

# Reusable channel base-names on the canary-ring model. These are the basenames
# WITHOUT the `-reusable` suffix (e.g. `auto-rebase`, not `auto-rebase-reusable`)
# and WITHOUT the `.yml` extension. dev-lead is included: it is ring-released too
# (its reusable lives in .github-private but the same tier topology applies).
readonly RING_REUSABLES=(
  auto-rebase
  dependency-audit
  dependabot-automerge
  dependabot-rebase
  agent-shield
  pr-review-mention
  dev-lead
  feature-ideation
  pr-auto-review
)

# ring_tier_for_repo <repo> -> next|ring0|ring1|stable
# Map a repo to its canary-ring tier (epic #495 topology):
#   next   — .github-private  (candidate / first soak)
#   ring0  — .github          (dogfood; self-hosts via @main, so the stub check
#                              skips it — this mapping is informational there)
#   ring1  — TalkTerm, bmad-bgreat-suite  (early fleet canary)
#   stable — everything else  (broad fleet)
ring_tier_for_repo() {
  case "$1" in
    .github-private)              printf 'next' ;;
    .github)                      printf 'ring0' ;;
    TalkTerm | bmad-bgreat-suite) printf 'ring1' ;;
    *)                            printf 'stable' ;;
  esac
  return 0
}

# ring_is_ring_reusable <channel-base> -> 0 if the reusable is on the ring model
ring_is_ring_reusable() {
  local name="$1" r
  for r in "${RING_REUSABLES[@]}"; do
    [ "$r" = "$name" ] && return 0
  done
  return 1
}

# ring_canonical_ref <channel-base> <repo> [major] -> the org-standard ref a stub
# in <repo> should pin: the channel tag for the repo's ring tier, e.g.
# `agent-shield/ring1` on a ring1 repo.
#
# With an optional MAJOR argument (major-scoped-channels epic #657, Phase F3) the
# ref becomes the major-scoped form `<channel>/v<major>-<tier>`, e.g.
# `agent-shield/v2-ring1`. Omit MAJOR for the legacy bare-tier form — consumers
# are still pinned to bare `<tier>` today and only migrate to the `v<M>-` form in
# F5, so the no-major call site behavior is unchanged.
ring_canonical_ref() {
  local name="$1" repo="$2" major="${3:-}"
  local tier; tier="$(ring_tier_for_repo "$repo")"
  if [ -n "$major" ]; then
    printf '%s/v%s-%s' "$name" "$major" "$tier"
  else
    printf '%s/%s' "$name" "$tier"
  fi
  return 0
}

# ring_pinned_major <ref> -> the major a consumer's channel ref has opted into, or
# empty for a legacy/unmajored bare-tier ref (major-scoped-channels epic #657,
# Phase F3). Pure. Given a `uses: …@<agent>/<channel>` ref (or bare channel):
#   `<agent>/v<M>-<tier>` -> `M`   (e.g. agent/v3-stable -> 3)
#   `<agent>/<tier>`      -> ``    (e.g. agent/stable    -> empty)
# Only the channel segment (after the last `/`) is inspected, so the agent/repo
# prefix is irrelevant.
ring_pinned_major() {
  local channel="${1##*/}"
  if [[ "$channel" =~ ^v([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# ring_accepted_refs <channel-base> <repo> -> newline-separated list of refs that
# a stub in <repo> may pin without being flagged/reverted. The FIRST line is the
# canonical tier channel; the rest are every ring channel, so a repo pinned to a
# HIGHER tier than its own (e.g. a ring1 repo still on /stable, or a /next pin
# promoted toward /stable) is never flagged and cut-release.sh promotions roll
# without the audit tripping mid-promotion.
#
# The pre-ring @v1/@v2 migration grace was DROPPED in #870 once the whole fleet
# was confirmed on `<name>/<tier>` channels (only .github's own dogfood callers
# still carry @v2, and both consumers skip .github). A stub on @v1/@v2/SHA/@main
# is now flagged — the migration is complete, so those are genuine drift.
ring_accepted_refs() {
  local name="$1" repo="$2"
  local canonical; canonical=$(ring_canonical_ref "$name" "$repo")
  printf '%s\n' "$canonical"
  printf '%s/next\n%s/ring0\n%s/ring1\n%s/stable\n' "$name" "$name" "$name" "$name" | grep -vFx "$canonical"
  return 0
}

# ring_legacy_csv <channel-base> <repo> -> the accepted refs EXCEPT the canonical
# one, comma-joined. Convenience for callers (the audit) that pass canonical and
# legacy separately.
ring_legacy_csv() {
  ring_accepted_refs "$1" "$2" | tail -n +2 | paste -sd, -
  return 0
}
