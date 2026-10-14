#!/usr/bin/env bash
# apply-rulesets.sh — Apply standard repository rulesets to combsmith repos
#
# Companion script to compliance-audit.sh. Creates or updates the rulesets defined in:
#   standards/github-settings.md#repository-rulesets
#
# Rulesets managed:
#   pr-quality    — pull request review requirements and merge policy
#   code-quality  — required status checks (CI, SonarCloud, CodeQL default setup, Dev-Lead Agent)
#
# Usage:
#   # Apply to a specific repo:
#   GH_TOKEN=<admin-token> ./scripts/apply-rulesets.sh <repo-name>
#
#   # Apply to all non-archived org repos:
#   GH_TOKEN=<admin-token> ./scripts/apply-rulesets.sh --all
#
#   # Dry run (show what would be changed):
#   GH_TOKEN=<admin-token> ./scripts/apply-rulesets.sh <repo-name> --dry-run
#
# Requirements:
#   - GH_TOKEN must have administration:write scope on the target repo(s)
#   - gh CLI must be installed
#   - jq must be installed

set -euo pipefail

ORG="combsmith"
DRY_RUN=false

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
err()   { echo "[ERROR] $*" >&2; }
skip()  { echo "[SKIP]  $*"; }

usage() {
  echo "Usage: $0 <repo-name> [--dry-run]"
  echo "       $0 --all [--dry-run]"
  echo ""
  echo "Environment variables:"
  echo "  GH_TOKEN   GitHub token with administration:write scope (required)"
  exit 1
}

# ---------------------------------------------------------------------------
# Detect required status checks from a repo's workflow files
# ---------------------------------------------------------------------------
detect_required_checks() {
  local repo="$1"
  local checks=()

  # Fetch list of workflow files present in the repo
  local workflows
  workflows=$(gh api "repos/$ORG/$repo/contents/.github/workflows" \
    --jq '.[].name' 2>/dev/null || echo "")

  # Helper: fetch workflow file content and extract the top-level `name:` field
  workflow_name() {
    local file="$1"
    gh api "repos/$ORG/$repo/contents/.github/workflows/$file" \
      --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null \
      | grep -m1 '^name:' \
      | sed 's/^name:[[:space:]]*//' \
      | tr -d '"'"'" \
      | sed "s/'//g" \
      || echo ""
  }

  # --- SonarCloud ---
  if echo "$workflows" | grep -qx "sonarcloud.yml"; then
    local sc_wf_name
    sc_wf_name=$(workflow_name "sonarcloud.yml")
    if [ -n "$sc_wf_name" ]; then
      checks+=("$sc_wf_name / SonarCloud")
    else
      checks+=("SonarCloud")
    fi
  fi

  # --- CodeQL (GitHub-managed default setup) ---
  # CodeQL is no longer driven by a per-repo workflow file. We probe the
  # default-setup API: if the state is "configured", GitHub publishes results
  # under the required-status-check context name `CodeQL` (single context,
  # regardless of how many languages are detected). See
  # standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup.
  #
  # Note: a stray .github/workflows/codeql.yml is drift and will be flagged
  # by compliance-audit.sh#check_codeql_default_setup. We do NOT fall back
  # to a workflow-derived check name here, because doing so would let drift
  # silently satisfy the rule and bypass remediation.
  local codeql_state codeql_err
  if codeql_err=$(gh api "repos/$ORG/$repo/code-scanning/default-setup" --jq '.state' 2>&1); then
    codeql_state="$codeql_err"  # on success, stdout holds the state value
    if [ "$codeql_state" = "configured" ]; then
      checks+=("CodeQL")
    else
      info "  CodeQL default setup not configured for $repo (state: $codeql_state) — skipping CodeQL required check. Run apply-repo-settings.sh first."
    fi
  else
    err "  Failed to probe CodeQL default-setup state for $repo. API error: $codeql_err"
    err "  Check that GH_TOKEN has code-scanning scope and the repo exists."
    return 1
  fi

  # --- Tier 1 centralized workflows ---
  # Caller-job-ids are fixed by the canonical stubs in
  # standards/workflows/, so the resulting reusable check names
  # (<caller-job-id> / <reusable-job-id-or-name>) are known constants.
  # See standards/ci-standards.md#centralization-tiers
  #
  # NOTE: claude-code / claude is intentionally NOT added as a required
  # check. claude-code-action's GitHub App refuses to mint a token for
  # any PR that touches workflow files, which would deadlock every
  # workflow-modifying PR. The check is still useful for review feedback
  # on normal PRs, but it must not be a merge gate.
  if echo "$workflows" | grep -qx "agent-shield.yml"; then
    checks+=("agent-shield / AgentShield")
  fi
  if echo "$workflows" | grep -qx "dependency-audit.yml"; then
    # Only the detect job runs unconditionally; per-ecosystem audit jobs
    # (npm audit, govulncheck, cargo audit, pip-audit, pnpm audit) are
    # gated on lockfile presence and report SKIPPED when absent. A
    # required-but-skipped check fails the gate, so we cannot require
    # the per-ecosystem jobs.
    checks+=("dependency-audit / Detect ecosystems")
  fi
  if echo "$workflows" | grep -qx "dev-lead.yml"; then
    checks+=("Dev-Lead Agent / dev-lead")
  fi
  # dependabot-automerge / dependabot-rebase are intentionally NOT
  # required: dependabot-automerge runs only on dependabot[bot] PRs and
  # dependabot-rebase runs only on push to main, neither of which are
  # regular contributor PRs.
  # feature-ideation runs on a schedule, never on PRs, so also not required.

  # --- CI Pipeline ---
  if echo "$workflows" | grep -qx "ci.yml"; then
    local ci_wf_name
    ci_wf_name=$(workflow_name "ci.yml")
    # Fetch ci.yml content once; used for first-job detection and secret-scan check below
    local ci_content ci_decoded
    ci_content=$(gh api "repos/$ORG/$repo/contents/.github/workflows/ci.yml" \
      --jq '.content' 2>/dev/null || echo "")
    ci_decoded=$(echo "$ci_content" | base64 -d 2>/dev/null || echo "")
    # Fetch the first job name from ci.yml
    local ci_job_name
    ci_job_name=$(echo "$ci_decoded" \
      | awk '
          /^jobs:/ { in_jobs=1; found=0; next }
          in_jobs && /^  [a-zA-Z0-9_-]+:/ && !found {
            job_id=substr($0, 3); gsub(/:.*/, "", job_id); current_job=job_id; next
          }
          in_jobs && /^    name:/ && !found {
            name=substr($0, 11); gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/["\x27]/, "", name)
            print name; found=1; exit
          }
        ' 2>/dev/null || echo "")
    if [ -z "$ci_job_name" ]; then
      ci_job_name="build"
    fi
    if [ -n "$ci_wf_name" ]; then
      checks+=("$ci_wf_name / $ci_job_name")
    else
      checks+=("$ci_job_name")
    fi

    # --- Secret scan (gitleaks) — included when ci.yml contains the gitleaks action ---
    if echo "$ci_decoded" | grep -qE 'uses:[[:space:]]*(gitleaks/gitleaks-action|zricethezav/gitleaks-action)@'; then
      checks+=("Secret scan (gitleaks)")
    fi
  fi

  # Output as newline-separated list (guard against empty array with set -u)
  [ "${#checks[@]}" -gt 0 ] && printf '%s\n' "${checks[@]}" || true
}

# ---------------------------------------------------------------------------
# Build the pr-quality ruleset JSON payload
# ---------------------------------------------------------------------------
build_pr_quality_ruleset_json() {
  jq -n '{
    name: "pr-quality",
    target: "branch",
    enforcement: "active",
    conditions: {
      ref_name: {
        include: ["~DEFAULT_BRANCH"],
        exclude: []
      }
    },
    rules: [
      {
        type: "pull_request",
        parameters: {
          required_approving_review_count: 1,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: true,
          require_last_push_approval: true,
          required_review_thread_resolution: true
        }
      },
      { type: "required_linear_history" },
      { type: "non_fast_forward" },
      { type: "deletion" }
    ],
    bypass_actors: [
      {
        actor_id: 0,
        actor_type: "OrganizationAdmin",
        bypass_mode: "always"
      },
      {
        actor_id: 3167543,
        actor_type: "Integration",
        bypass_mode: "always"
      }
    ]
  }'
}

# ---------------------------------------------------------------------------
# Build the code-quality ruleset JSON payload
# ---------------------------------------------------------------------------
build_ruleset_json() {
  local name="$1"
  shift
  local checks=("$@")

  # Build the required_status_checks array
  local checks_json
  checks_json=$(printf '%s\n' "${checks[@]}" | jq -R '{"context": .}' | jq -s '.')

  jq -n \
    --arg name "$name" \
    --argjson checks "$checks_json" \
    '{
      name: $name,
      target: "branch",
      enforcement: "active",
      conditions: {
        ref_name: {
          include: ["~DEFAULT_BRANCH"],
          exclude: []
        }
      },
      rules: [
        {
          type: "required_status_checks",
          parameters: {
            strict_required_status_checks_policy: true,
            do_not_enforce_on_create: false,
            required_status_checks: $checks
          }
        }
      ],
      bypass_actors: [
        {
          actor_id: 0,
          actor_type: "OrganizationAdmin",
          bypass_mode: "always"
        },
        {
          actor_id: 3167543,
          actor_type: "Integration",
          bypass_mode: "always"
        }
      ]
    }'
}

# ---------------------------------------------------------------------------
# Apply rulesets to a single repo
# ---------------------------------------------------------------------------
apply_rulesets() {
  local repo="$1"
  info "Processing $ORG/$repo ..."

  # Fetch existing rulesets
  local existing_rulesets
  existing_rulesets=$(gh api "repos/$ORG/$repo/rulesets" 2>/dev/null || echo "[]")

  # --- pr-quality ruleset ---
  local pr_quality_id
  pr_quality_id=$(echo "$existing_rulesets" | jq -r '.[] | select(.name == "pr-quality") | .id' 2>/dev/null || echo "")

  local pr_quality_payload
  pr_quality_payload=$(build_pr_quality_ruleset_json)

  if [ "$DRY_RUN" = true ]; then
    if [ -n "$pr_quality_id" ]; then
      skip "  DRY_RUN — would UPDATE pr-quality ruleset (id=$pr_quality_id) for $ORG/$repo"
    else
      skip "  DRY_RUN — would CREATE pr-quality ruleset for $ORG/$repo"
    fi
    echo "$pr_quality_payload" | jq '.'
  elif [ -n "$pr_quality_id" ]; then
    info "  Updating existing pr-quality ruleset (id=$pr_quality_id) ..."
    gh api -X PUT "repos/$ORG/$repo/rulesets/$pr_quality_id" \
      --input <(echo "$pr_quality_payload") > /dev/null
    ok "  pr-quality ruleset updated for $ORG/$repo"
  else
    info "  Creating pr-quality ruleset ..."
    gh api -X POST "repos/$ORG/$repo/rulesets" \
      --input <(echo "$pr_quality_payload") > /dev/null
    ok "  pr-quality ruleset created for $ORG/$repo"
  fi

  # --- code-quality ruleset ---
  local existing_id
  existing_id=$(echo "$existing_rulesets" | jq -r '.[] | select(.name == "code-quality") | .id' 2>/dev/null || echo "")

  # Detect required checks for this repo
  local checks=()
  mapfile -t checks < <(detect_required_checks "$repo")

  if [ "${#checks[@]}" -eq 0 ]; then
    err "  No required checks detected for $ORG/$repo — skipping code-quality ruleset"
    return 1
  fi

  info "  Detected required checks:"
  for c in "${checks[@]}"; do
    info "    - $c"
  done

  local payload
  payload=$(build_ruleset_json "code-quality" "${checks[@]}")

  if [ "$DRY_RUN" = true ]; then
    if [ -n "$existing_id" ]; then
      skip "  DRY_RUN — would UPDATE code-quality ruleset (id=$existing_id) for $ORG/$repo"
    else
      skip "  DRY_RUN — would CREATE code-quality ruleset for $ORG/$repo"
    fi
    echo "$payload" | jq '.'
    return 0
  fi

  if [ -n "$existing_id" ]; then
    info "  Updating existing code-quality ruleset (id=$existing_id) ..."
    gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" \
      --input <(echo "$payload") > /dev/null
    ok "  code-quality ruleset updated for $ORG/$repo"
  else
    info "  Creating code-quality ruleset ..."
    gh api -X POST "repos/$ORG/$repo/rulesets" \
      --input <(echo "$payload") > /dev/null
    ok "  code-quality ruleset created for $ORG/$repo"
  fi
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
  usage
fi

if [ -z "${GH_TOKEN:-}" ]; then
  err "GH_TOKEN is required — provide a token with administration:write scope"
  exit 1
fi

export GH_TOKEN

TARGET=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --all)     TARGET="--all" ;;
    -*)        err "Unknown flag: $arg"; usage ;;
    *)         TARGET="$arg" ;;
  esac
done

if [ -z "$TARGET" ]; then
  usage
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$TARGET" = "--all" ]; then
  info "Fetching all non-archived repos in $ORG ..."
  repos=$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)

  if [ -z "$repos" ]; then
    err "No repositories found in $ORG — check GH_TOKEN permissions"
    exit 1
  fi

  failed=0
  for repo in $repos; do
    apply_rulesets "$repo" || failed=$((failed + 1))
  done

  if [ "$failed" -gt 0 ]; then
    err "$failed repo(s) failed — check output above for details"
    exit 1
  fi

  ok "All repos processed successfully"
else
  apply_rulesets "$TARGET"
fi
