#!/usr/bin/env bash
# automerge-standards-sync.sh — merge `standards-sync` PRs THROUGH branch
# protection, with no `--admin` bypass and no human click (issue #852, Epic #850).
#
# The problem
# -----------
# The `pr-quality` ruleset (standards/rulesets/pr-quality.json) requires a
# code-owner approval, `require_last_push_approval`, and — implicitly — that the
# approval is not the PR author's own. CODEOWNERS is `* @combsmith/org-leads`
# = {don-petry, donpetry-bot}. On a standards-sync PR author=don-petry (cannot
# self-approve) and last-pusher=donpetry-bot (last-push-approval disqualifies its
# own approval), so BOTH code-owners are disqualified and the only historical way
# to merge was an org-admin `--admin` bypass — automation could not merge its own
# remediation.
#
# The fix (issue Options 1 + 2, "through protection, not around it")
# ------------------------------------------------------------------
#  1. Distinct review identity — approve as the org-leads code-owner that is
#     NEITHER the author NOR the last pusher. That single approval legitimately
#     satisfies require_code_owner_review + require_last_push_approval + not-own-PR.
#  2. Native auto-merge — `gh pr merge --auto --squash`, so GitHub merges the PR
#     itself once the required status checks are green. The merge goes THROUGH the
#     ruleset (all required checks + the now-satisfied approval), never around it.
#
# This script NEVER passes `--admin` and never mutates the ruleset; the required
# status-check gates are untouched. Every action is logged for audit.
#
# Usage:
#   automerge-standards-sync.sh --repo <owner/repo> --pr <number> [--dry-run]
#   automerge-standards-sync.sh --repo <owner/repo> [--dry-run]   # sweep open PRs
#
# Options:
#   --repo <owner/repo>   Target repository (required). Works for the SKIP_REPOS
#                         meta-repos too (e.g. combsmith/.github-private).
#   --pr <number>         Operate on a single PR. Omit to sweep every open PR that
#                         carries the standards-sync label.
#   --dry-run             Print intended actions; make no mutating gh calls.
#   --approver-login <u>  Pin the approving code-owner instead of auto-resolving.
#
# Environment:
#   GH_TOKEN         Token for read/list/merge calls (repo scope).
#   APPROVER_TOKEN   Token for the DISTINCT approver identity used to post the
#                    approval review. Required unless --dry-run. In production the
#                    approver's own PAT is supplied here so the approval is
#                    attributable to that identity (audit trail).
#   SYNC_LABEL           Merge-eligibility label (default: standards-sync).
#   SYNC_BRANCH_PREFIX   Required head-branch prefix (default: standards-sync).
#   ORG_LEADS_MEMBERS    Comma-separated code-owner set that satisfies CODEOWNERS
#                        (default: don-petry,donpetry-bot).
#   TRUSTED_AUTHORS      Comma-separated allowlist of PR authors whose standards-sync
#                        PRs are eligible (default: value of ORG_LEADS_MEMBERS).

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
for _cmd in gh jq; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "::error::${_cmd} is required but not installed." >&2; exit 1; }
done
unset _cmd

# Provenance gate (#1386): approve only a head that is still a pure standards
# deploy. The allowed paths come from deploy-standard-workflows.sh itself; if
# they cannot be loaded every PR is skipped (fail closed).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/standards-sync-provenance.sh
source "$SCRIPT_DIR/lib/standards-sync-provenance.sh"
SSP_ALLOWED_PATHS="$(ssp_allowed_paths "$SCRIPT_DIR/deploy-standard-workflows.sh" || true)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SYNC_LABEL="${SYNC_LABEL:-standards-sync}"
SYNC_BRANCH_PREFIX="${SYNC_BRANCH_PREFIX:-standards-sync}"
ORG_LEADS_MEMBERS="${ORG_LEADS_MEMBERS:-don-petry,donpetry-bot}"
TRUSTED_AUTHORS="${TRUSTED_AUTHORS:-$ORG_LEADS_MEMBERS}"

REPO=""
PR_NUMBER=""
DRY_RUN=false
APPROVER_LOGIN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)           REPO="${2:?--repo needs a value}"; shift 2 ;;
    --pr)             PR_NUMBER="${2:?--pr needs a value}"; shift 2 ;;
    --approver-login) APPROVER_LOGIN="${2:?--approver-login needs a value}"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        sed -n '1,52p' "$0"; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] || { echo "::error::--repo <owner/repo> is required" >&2; exit 2; }
if [ "$DRY_RUN" != "true" ] && [ -z "${APPROVER_TOKEN:-}" ]; then
  echo "::error::APPROVER_TOKEN is required for a live run (the distinct approver's token). Use --dry-run to preview." >&2
  exit 2
fi

# in_list <needle> <comma-separated-haystack>
in_list() {
  local needle="$1" hay="$2" item _items
  IFS=',' read -ra _items <<< "$hay"
  for item in "${_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# resolve_approver <author> <last_pusher> — echo the code-owner that is neither
# the author nor the last pusher, or empty when none exists (the deadlock).
resolve_approver() {
  local author="$1" last="$2" item _members
  IFS=',' read -ra _members <<< "$ORG_LEADS_MEMBERS"
  for item in "${_members[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] && continue
    if [ "$item" != "$author" ] && [ "$item" != "$last" ]; then
      printf '%s' "$item"
      return 0
    fi
  done
  return 0
}

# process_pr <pr-number> — returns 0 on success/skip, 1 on an unresolved deadlock.
process_pr() {
  local pr="$1"
  local pr_json author head last url labels

  pr_json=$(gh pr view "$pr" --repo "$REPO" \
    --json number,url,author,headRefName,headRefOid,labels,commits 2>/dev/null) || {
    echo "  [warn] ${REPO}#${pr} — could not read PR" >&2
    return 0
  }

  author=$(jq -r '.author.login // empty' <<< "$pr_json")
  head=$(jq -r '.headRefName // empty' <<< "$pr_json")
  url=$(jq -r '.url // empty' <<< "$pr_json")
  last=$(jq -r '.commits[-1].authors[0].login // empty' <<< "$pr_json")
  labels=$(jq -r '.labels[].name' <<< "$pr_json" 2>/dev/null || true)
  [ -n "$url" ] || url="${REPO}#${pr}"

  # --- Eligibility gates (auditable trusted source) ---
  if ! grep -qxF "$SYNC_LABEL" <<< "$labels"; then
    echo "  [skip] ${url} — missing '${SYNC_LABEL}' label"
    return 0
  fi
  if [[ "$head" != "${SYNC_BRANCH_PREFIX}/"* ]]; then
    echo "  [skip] ${url} — head branch '${head}' is not a '${SYNC_BRANCH_PREFIX}/' branch"
    return 0
  fi
  if ! in_list "$author" "$TRUSTED_AUTHORS"; then
    echo "  [skip] ${url} — author '${author}' is not in the trusted allowlist"
    return 0
  fi
  # Who opened the PR says nothing about what is on its branch now. Verify the
  # current head (commits, pushes, changed paths) is still the deployer's
  # standards-only change, and bind the approval + auto-merge to that SHA.
  local head_sha reject
  head_sha=$(jq -r '.headRefOid // empty' <<< "$pr_json")
  if ! reject=$(ssp_fetch_and_verify "$REPO" "$pr" "$head" "$head_sha" "$author" "$SSP_ALLOWED_PATHS"); then
    echo "::warning::${url} — not approving: provenance not verified (${reject})"
    echo "  [skip] ${url} — provenance not verified: ${reject}"
    return 0
  fi

  # --- Resolve the distinct review identity (Option 1) ---
  local approver
  if [ -n "$APPROVER_LOGIN" ]; then
    if ! in_list "$APPROVER_LOGIN" "$ORG_LEADS_MEMBERS"; then
      echo "::error::approver '${APPROVER_LOGIN}' is not an org-leads code-owner (${ORG_LEADS_MEMBERS})" >&2
      return 1
    fi
    if [ "$APPROVER_LOGIN" = "$author" ] || [ "$APPROVER_LOGIN" = "$last" ]; then
      echo "::error::${url} — pinned approver '${APPROVER_LOGIN}' is the author or last pusher; cannot satisfy require_last_push_approval / not-own-PR" >&2
      return 1
    fi
    approver="$APPROVER_LOGIN"
  else
    approver=$(resolve_approver "$author" "$last")
  fi

  if [ -z "$approver" ]; then
    echo "::error::${url} — reviewer DEADLOCK: author='${author}' and last-pusher='${last}' consume every code-owner {${ORG_LEADS_MEMBERS}}, so no distinct code-owner can approve. Resolve by giving the PR a single push identity (author == last pusher) or by adding a distinct org-leads code-owner. NOT merging via --admin." >&2
    return 1
  fi

  # --- Approve as the distinct identity + enable native auto-merge (Option 2) ---
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] ${url} — would approve as '${approver}' (distinct code-owner) and enable native auto-merge (squash); admin=none"
    echo "AUDIT pr=${url} approver=${approver} merge=native-auto-merge admin=none dry_run=true"
    return 0
  fi

  # Verify APPROVER_TOKEN actually authenticates as the resolved approver, so the
  # audit line and the review body attribute the approval to the real identity
  # (a token/login mismatch from misconfiguration or rotation must not silently
  # post a misattributed code-owner approval).
  local token_login
  token_login=$(GH_TOKEN="$APPROVER_TOKEN" gh api user --jq '.login' 2>/dev/null || true)
  if [ -z "$token_login" ]; then
    echo "::error::${url} — APPROVER_TOKEN did not authenticate (gh api user failed); refusing to post an unattributable approval" >&2
    return 1
  fi
  if [ "$token_login" != "$approver" ]; then
    echo "::error::${url} — APPROVER_TOKEN authenticates as '${token_login}', not the resolved approver '${approver}'; refusing to post a misattributed approval" >&2
    return 1
  fi

  echo "  [approve] ${url} — approving as '${approver}' (distinct code-owner: neither author nor last pusher)"
  # The review is posted against the verified head (commit_id), so it never
  # covers a commit pushed after verification.
  if ! GH_TOKEN="$APPROVER_TOKEN" gh api "repos/${REPO}/pulls/${pr}/reviews" --method POST \
      -f event=APPROVE -f commit_id="$head_sha" \
      -f body="Code-owner approval by @${approver} of verified head ${head_sha} on this standards-sync PR (issues #852, #1386). Merges via native auto-merge on required-checks-green — through branch protection, no admin bypass." \
      --silent; then
    echo "::error::${url} — failed to post approval review as '${approver}'" >&2
    return 1
  fi

  # Re-check the head before enabling auto-merge: if it moved, the approval is
  # for a commit that is no longer the head and auto-merge must not be enabled.
  local now_sha
  now_sha=$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
  if [ "$now_sha" != "$head_sha" ]; then
    echo "::error::${url} — head moved from ${head_sha} to '${now_sha}' after verification; approval is bound to ${head_sha}, NOT enabling auto-merge" >&2
    return 1
  fi

  echo "  [automerge] ${url} — enabling native auto-merge (squash) for head ${head_sha}; merges on required-checks-green through branch protection"
  if ! gh pr merge "$pr" --repo "$REPO" --auto --squash --match-head-commit "$head_sha"; then
    echo "::error::${url} — failed to enable native auto-merge" >&2
    return 1
  fi

  echo "AUDIT pr=${url} approver=${approver} head=${head_sha} merge=native-auto-merge admin=none"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== Standards-sync auto-merge ==="
echo "  Repo:            ${REPO}"
echo "  Label:           ${SYNC_LABEL}"
echo "  Code-owners:     ${ORG_LEADS_MEMBERS}"
echo "  Dry run:         ${DRY_RUN}"
echo ""

rc=0
if [ -n "$PR_NUMBER" ]; then
  process_pr "$PR_NUMBER" || rc=1
else
  numbers=$(gh pr list --repo "$REPO" --state open --label "$SYNC_LABEL" \
    --json number --jq '.[].number' 2>/dev/null || true)
  if [ -z "$numbers" ]; then
    echo "  No open '${SYNC_LABEL}' PRs in ${REPO}."
  else
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      process_pr "$n" || rc=1
    done <<< "$numbers"
  fi
fi

echo ""
if [ "$rc" -eq 0 ]; then
  echo "=== Done — no --admin bypass used ==="
else
  echo "=== Completed with unresolved deadlock(s); see errors above (no --admin used) ===" >&2
fi
exit "$rc"
