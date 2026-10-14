#!/usr/bin/env bash
# deploy-standard-workflows.sh — Deploy org-standard workflow stubs to all repos.
#
# Reads canonical stubs from standards/workflows/ and deploys them into every
# repo in the combsmith org by opening a pull request per repo (via the
# shared scripts/lib/standards-deploy.sh primitive). Only workflows that have a
# template in standards/workflows/ AND appear in the DEPLOYABLE_WORKFLOWS list
# below are eligible — tech-stack-specific workflows (ci.yml, sonarcloud.yml)
# must be set up manually.
#
# Deployment is PR-based, never a direct push to the default branch: a direct
# Contents-API push is rejected (HTTP 409) on repos whose ruleset enforces
# required status checks, and bypasses review/CI on the repos where it would
# succeed. Opening a PR works uniformly on protected and unprotected repos and
# leaves an auditable, CI-gated record. The PRs are labeled `standards-sync` and
# left for the normal review/auto-merge pipeline — this script never merges and
# never uses --admin. See combsmith/.github#478.
#
# Usage:
#   deploy-standard-workflows.sh [options]
#
# Options:
#   --dry-run              Print planned actions without opening any PRs.
#   --workflow <name.yml>  Deploy only this workflow (default: all deployable).
#   --repo <name>          Target a single repo instead of all org repos.
#   --force                Re-deploy even if the file looks correct (re-syncs).
#
# Requirements:
#   GH_TOKEN (or gh auth login) with repo scope (branch + PR creation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/standards-deploy.sh
source "$SCRIPT_DIR/lib/standards-deploy.sh"
# Canary-ring pin model — shared with compliance-audit.sh so this sweep's notion
# of "drift" matches the audit's "non-compliant" and never reverts a repo's
# intentional ring/next pin back to the template's stable channel (#482).
# shellcheck source=scripts/lib/ring-pins.sh
source "$SCRIPT_DIR/lib/ring-pins.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ORG="combsmith"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STANDARDS_DIR="$REPO_ROOT/standards/workflows"

# Branch prefix + label for the PRs this script opens.
SYNC_BRANCH_PREFIX="standards-sync"
SYNC_LABEL="standards-sync"

# Repos exempt from blanket standard-workflow deployment.
#   .github         — self-host source of truth; its own callers use local refs
#                     (e.g. add-to-project.yml pins ./.github/...), which a
#                     channel-pinned stub must never overwrite.
#   .github-private — self-manages its workflow fleet (dev-lead runs inline, etc).
# A repo here may still opt into a *specific* workflow via SKIP_OVERRIDES below.
SKIP_REPOS=(".github" ".github-private")

# Per-workflow opt-ins for otherwise-skipped repos. Keyed by workflow filename;
# value is a space-separated list of SKIP_REPOS that should still receive it.
# .github-private participates in the org Initiatives board, so it receives the
# add-to-project.yml caller (the org board is a single shared target — the stub
# is identical for every repo) while staying exempt from all other stubs.
declare -A SKIP_OVERRIDES=(
  ["add-to-project.yml"]=".github-private"
)

# Workflows deployable from standards/workflows/<name> verbatim.
# Excludes ci.yml, sonarcloud.yml (tech-stack-specific) and
# feature-ideation.yml (requires repo-specific project_context input).
DEPLOYABLE_WORKFLOWS=(
  pr-review-mention.yml
  dev-lead.yml
  agent-shield.yml
  auto-rebase.yml
  dependabot-automerge.yml
  dependabot-rebase.yml
  dependency-audit.yml
  add-to-project.yml
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
TARGET_WORKFLOW=""
TARGET_REPO=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --force)     FORCE=true;   shift ;;
    --workflow)  TARGET_WORKFLOW="$2"; shift 2 ;;
    --repo)      TARGET_REPO="$2";     shift 2 ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[deploy] $*"; }
skip() { echo "[deploy] SKIP  $*"; }
dry()  { echo "[deploy] DRY   $*"; }
ok()   { echo "[deploy] OK    $*"; }
err()  { echo "[deploy] ERROR $*" >&2; }

is_skipped_repo() {
  local repo="$1" s
  for s in "${SKIP_REPOS[@]}"; do
    [[ "$repo" == "$s" ]] && return 0
  done
  return 1
}

# True if a normally-skipped repo has opted into this specific workflow via
# SKIP_OVERRIDES — lets a self-managed repo receive one stub while staying
# exempt from the rest.
repo_opts_into() {
  local repo="$1" workflow="$2"
  local opt_in="${SKIP_OVERRIDES[$workflow]:-}"
  [[ -z "$opt_in" ]] && return 1

  # Split the space-separated opt-in list into an array (read -r -a avoids the
  # pathname expansion an unquoted expansion would be subject to).
  local -a allowed_repos
  read -r -a allowed_repos <<< "$opt_in"
  local r
  for r in "${allowed_repos[@]}"; do
    [[ "$repo" == "$r" ]] && return 0
  done
  return 1
}

# Fetch a file from the repo API in one call; outputs "sha<TAB>decoded-content".
# Returns empty string on 404.
fetch_existing() {
  local repo="$1" path="$2"
  local raw
  raw=$(gh api "repos/$ORG/$repo/contents/$path" 2>/dev/null) || { echo ""; return; }
  local sha encoded decoded
  sha=$(echo "$raw" | jq -r '.sha // empty')
  encoded=$(echo "$raw" | jq -r '.content // empty')
  decoded=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
  printf '%s\t%s' "$sha" "$decoded"
}

# True if the existing decoded content already has the canonical uses: reference
# for this workflow (extracted from the template itself, so it tracks version bumps).
#
# Ring-aware (#482): templates pin a moving channel tag `<base>/stable`, but a
# repo on a non-stable ring tier legitimately pins `<base>/<tier>` (e.g.
# `<base>/ring1`). For those reusables the stub is compliant when it pins ANY ref
# the shared ring model accepts for THIS repo (its tier channel + the transitional
# legacy grace) — so the sweep never reverts an intentional ring/next pin. Non-ring
# templates (e.g. add-to-project, feature-ideation@v1) keep the exact-match rule.
is_already_compliant() {
  local existing_content="$1" template="$2" repo="$3"
  local expected_uses
  expected_uses=$(grep -E '^[[:space:]]*uses:' "$template" | head -1 | sed 's/^[[:space:]]*uses:[[:space:]]*//' | tr -d '\r')
  [[ -z "$expected_uses" ]] && return 1

  local prefix="${expected_uses%@*}" ref_after="${expected_uses##*@}" base
  if [[ "$prefix" =~ /([a-z0-9-]+)-reusable\.yml$ ]]; then
    base="${BASH_REMATCH[1]}"
    # Only treat it as ring-managed if the reusable is on the ring model AND the
    # template pins a channel tag (not a frozen @vX / SHA).
    if ring_is_ring_reusable "$base" && [[ "$ref_after" =~ ^${base}/(stable|next|ring[0-9]+)$ ]]; then
      local ref
      while IFS= read -r ref; do
        [[ -n "$ref" ]] && grep -qF "${prefix}@${ref}" <<< "$existing_content" && return 0
      done < <(ring_accepted_refs "$base" "$repo")
      return 1
    fi
  fi

  grep -qF "$expected_uses" <<< "$existing_content" && return 0 || return 1
}

# Build the PR body for a batched stub deployment (one PR per repo).
batch_pr_body() {
  local w lines=""
  for w in "$@"; do lines+="- \`${w}\`"$'\n'; done
  printf 'Syncs the following org-standard workflow stub(s) from `%s/.github` (`standards/workflows/`), deployed verbatim:\n\n%s\nOpened by `scripts/deploy-standard-workflows.sh`. Stubs are thin callers; all behaviour lives in the reusables. See `standards/ci-standards.md`. Labeled `%s` and left for the normal review/auto-merge pipeline — the deploy script never merges directly.\n' \
    "$ORG" "$lines" "$SYNC_LABEL"
}

# ---------------------------------------------------------------------------
# Deploy all drifted stubs for a single repo as ONE batched standards-sync PR.
# ---------------------------------------------------------------------------
deploy_repo() {
  local repo="$1"

  # Fully-exempt repos (no per-workflow opt-in) skip with a single log line.
  if is_skipped_repo "$repo"; then
    local opts_in_any=false w
    for w in "${WORKFLOWS[@]}"; do
      if repo_opts_into "$repo" "$w"; then opts_in_any=true; break; fi
    done
    if [[ "$opts_in_any" == "false" ]]; then skip "$repo (exempt)"; return; fi
  fi

  # Collect the drifted stubs for this repo (path/template pairs + names).
  local -a paths=() templates=() names=()
  local workflow template target_path raw existing_sha existing_content
  for workflow in "${WORKFLOWS[@]}"; do
    if is_skipped_repo "$repo" && ! repo_opts_into "$repo" "$workflow"; then
      skip "$repo/$workflow (exempt)"
      continue
    fi
    template="$STANDARDS_DIR/$workflow"
    target_path=".github/workflows/$workflow"
    if [[ ! -f "$template" ]]; then
      err "No template at $template — skipping $workflow for $repo"
      continue
    fi
    raw=$(fetch_existing "$repo" "$target_path")
    existing_sha="${raw%%$'\t'*}"
    existing_content="${raw#*$'\t'}"
    if [[ -n "$existing_sha" ]] && [[ "$FORCE" == "false" ]] && is_already_compliant "$existing_content" "$template" "$repo"; then
      skip "$repo/$target_path already compliant"
      continue
    fi
    paths+=("$target_path"); templates+=("$template"); names+=("$workflow")
  done

  [[ "${#names[@]}" -eq 0 ]] && return  # nothing drifted for this repo

  local n="${#names[@]}" list branch
  list=$(IFS=', '; echo "${names[*]}")
  branch="${SYNC_BRANCH_PREFIX}/workflows-$(date -u +%Y%m%d)"
  local title="chore: sync ${n} org-standard workflow stub(s) from ${ORG}/.github"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would open PR for $repo (branch $branch) — ${n} stub(s): $list"
    return
  fi

  # Interleave (path, template) into the variadic file-pair args.
  local -a filepairs=() k
  for (( k = 0; k < n; k++ )); do filepairs+=("${paths[k]}" "${templates[k]}"); done

  local body outcome
  body=$(batch_pr_body "${names[@]}")
  outcome=$(sd_deploy_files_via_pr "$ORG/$repo" "$branch" "$SYNC_LABEL" "$title" "$body" "${filepairs[@]}") || true

  case "$outcome" in
    "OPENED "*)       ok   "$repo — opened ${outcome#OPENED } (${n} stub(s): $list)" ;;
    "SKIP_PR_OPEN "*) skip "$repo — sync PR #${outcome#SKIP_PR_OPEN } already open" ;;
    "FAILED "*)       err  "$repo — ${outcome#FAILED }" ;;
    *)                err  "$repo — unexpected outcome: ${outcome:-<none>}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
[[ "$DRY_RUN" == "true" ]] && log "DRY RUN — no PRs will be opened"

# Resolve target repos using pagination (handles orgs with >100 repos).
declare -a REPOS
if [[ -n "$TARGET_REPO" ]]; then
  REPOS=("$TARGET_REPO")
else
  mapfile -t REPOS < <(gh repo list "$ORG" --limit 500 --no-archived --json name -q '.[].name')
fi

# Resolve target workflows
declare -a WORKFLOWS
if [[ -n "$TARGET_WORKFLOW" ]]; then
  WORKFLOWS=("$TARGET_WORKFLOW")
else
  WORKFLOWS=("${DEPLOYABLE_WORKFLOWS[@]}")
fi

log "Deploying ${#WORKFLOWS[@]} workflow(s) to ${#REPOS[@]} repo(s)"

for repo in "${REPOS[@]}"; do
  deploy_repo "$repo"
done

log "Done."
