#!/usr/bin/env bash
# compliance-audit.sh — Weekly org-wide compliance audit
#
# Checks every combsmith repository against the standards defined in:
#   standards/ci-standards.md
#   standards/dependabot-policy.md
#   standards/github-settings.md
#   standards/push-protection.md
#
# Outputs:
#   $REPORT_DIR/findings.json   — machine-readable findings
#   $REPORT_DIR/summary.md      — human-readable report
#
# Environment variables:
#   GH_TOKEN        — GitHub token with repo/org scope (required)
#   REPORT_DIR      — directory for output files (default: mktemp -d)
#   DRY_RUN         — set to "true" to skip issue creation (default: false)
#   CREATE_ISSUES   — set to "false" to skip issue creation (default: true)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ORG="combsmith"
AUDIT_LABEL="compliance-audit"
AUDIT_LABEL_COLOR="7057ff"
AUDIT_LABEL_DESC="Automated compliance audit finding"
REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"
DRY_RUN="${DRY_RUN:-false}"
CREATE_ISSUES="${CREATE_ISSUES:-true}"

FINDINGS_FILE="$REPORT_DIR/findings.json"
SUMMARY_FILE="$REPORT_DIR/summary.md"
ISSUES_FILE="$REPORT_DIR/issues.json"

REQUIRED_WORKFLOWS=(ci.yml sonarcloud.yml claude.yml dependabot-automerge.yml dependency-audit.yml agent-shield.yml pr-review-mention.yml)
# Note: codeql.yml is intentionally NOT in REQUIRED_WORKFLOWS. CodeQL is now
# configured via GitHub-managed default setup (Settings → Code security →
# Code scanning), not a per-repo workflow file. The check_codeql_default_setup
# function below verifies the API state and treats stray codeql.yml files
# as drift to be removed. See standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup.

# name:hex-color:description (color without leading #)
REQUIRED_LABEL_SPECS=(
  "security:d93f0b:Security-related PRs and issues"
  "dependencies:0075ca:Dependency update PRs"
  "scorecard:d93f0b:OpenSSF Scorecard findings (auto-created)"
  "bug:d73a4a:Bug reports"
  "enhancement:a2eeef:Feature requests"
  "documentation:0075ca:Documentation changes"
  "in-progress:fbca04:An agent is actively working this issue"
)

# App IDs whose auto_trigger_checks must be disabled org-wide.
# 1236702 = Claude (anthropics/claude-code-action)
# 347564  = CodeRabbit
CHECK_SUITE_APP_IDS=(1236702 347564)

REQUIRED_SETTINGS_BOOL=(
  "allow_auto_merge:true:warning:Allow auto-merge must be enabled for Dependabot workflow"
  "delete_branch_on_merge:true:warning:Automatically delete head branches must be enabled"
  "has_wiki:false:warning:Wiki should be disabled — documentation lives in the repo"
  "has_issues:true:error:Issue tracking must be enabled"
  "has_discussions:true:error:Discussions must be enabled for ideation and community engagement"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
findings_count=0

add_finding() {
  local repo="$1" category="$2" check="$3" severity="$4" detail="$5" standard_ref="${6:-}"

  findings_count=$((findings_count + 1))
  local finding
  finding=$(jq -n \
    --arg repo "$repo" \
    --arg category "$category" \
    --arg check "$check" \
    --arg severity "$severity" \
    --arg detail "$detail" \
    --arg standard_ref "$standard_ref" \
    '{repo:$repo,category:$category,check:$check,severity:$severity,detail:$detail,standard_ref:$standard_ref}')

  jq --argjson f "$finding" '. += [$f]' "$FINDINGS_FILE" > "$FINDINGS_FILE.tmp"
  mv "$FINDINGS_FILE.tmp" "$FINDINGS_FILE"
}

log() { echo "::group::$*" >&2; }
log_end() { echo "::endgroup::" >&2; }
info() { echo "[INFO] $*" >&2; }
warn() { echo "::warning::$*" >&2; }

# Retry wrapper for gh api calls (handles rate limits)
gh_api() {
  local retries=3
  for i in $(seq 1 $retries); do
    if gh api "$@" 2>/dev/null; then
      return 0
    fi
    if [ "$i" -lt "$retries" ]; then
      sleep $((i * 2))
    else
      info "gh api $1 failed after $retries retries" >&2
    fi
  done
  return 1
}

# Source the shared push-protection library — provides pp_run_all_checks()
# and the PP_REQUIRED_SA_SETTINGS list. Sourced AFTER gh_api() and
# add_finding() are defined, since the lib's check functions call them.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-protection.sh
. "$SCRIPT_DIR/lib/push-protection.sh"

# ---------------------------------------------------------------------------
# Ecosystem detection
# ---------------------------------------------------------------------------
detect_ecosystems() {
  local repo="$1"
  ECOSYSTEMS=()

  # Check for common ecosystem markers via the repo tree
  local tree
  tree=$(gh_api "repos/$ORG/$repo/git/trees/HEAD?recursive=1" --jq '.tree[].path' 2>/dev/null || echo "")

  if grep -qE '(^|/)package\.json$' <<< "$tree"; then
    ECOSYSTEMS+=("npm")
  fi
  if grep -qE '(^|/)pnpm-lock\.yaml$' <<< "$tree"; then
    # Override npm with pnpm if lock file present, or add pnpm directly
    if [[ " ${ECOSYSTEMS[*]} " == *" npm "* ]]; then
      ECOSYSTEMS=("${ECOSYSTEMS[@]/npm/pnpm}")
    else
      ECOSYSTEMS+=("pnpm")
    fi
  fi
  if grep -qE '(^|/)go\.mod$' <<< "$tree"; then
    ECOSYSTEMS+=("go")
  fi
  if grep -qE '(^|/)Cargo\.toml$' <<< "$tree"; then
    ECOSYSTEMS+=("rust")
  fi
  if grep -qE '(^|/)(pyproject\.toml|requirements\.txt)$' <<< "$tree"; then
    ECOSYSTEMS+=("python")
  fi
  if grep -qE '\.tf$' <<< "$tree"; then
    ECOSYSTEMS+=("terraform")
  fi
  if grep -qE '\.github/workflows/.*\.ya?ml$' <<< "$tree"; then
    ECOSYSTEMS+=("github-actions")
  fi
  # BMAD Method: detected via either the active install dir (`_bmad/`) or
  # the planning artifacts output dir (`_bmad-output/`). Repos may have one,
  # the other, or both depending on the BMAD workflow stage.
  if grep -qE '(^|/)_bmad(-output)?/' <<< "$tree"; then
    ECOSYSTEMS+=("bmad-method")
  fi
}

# ---------------------------------------------------------------------------
# Check: Required workflows exist
# ---------------------------------------------------------------------------
check_required_workflows() {
  local repo="$1"

  for wf in "${REQUIRED_WORKFLOWS[@]}"; do
    if ! gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.name' > /dev/null 2>&1; then
      add_finding "$repo" "ci-workflows" "missing-$wf" "error" \
        "Required workflow \`$wf\` is missing" \
        "standards/ci-standards.md#required-workflows"
    fi
  done

  # Conditional: bmad-method repos must have feature-ideation workflow
  if [[ " ${ECOSYSTEMS[*]} " == *" bmad-method "* ]]; then
    if ! gh_api "repos/$ORG/$repo/contents/.github/workflows/feature-ideation.yml" --jq '.name' > /dev/null 2>&1; then
      add_finding "$repo" "ci-workflows" "missing-feature-ideation.yml" "error" \
        "BMAD Method repo must have \`feature-ideation.yml\` workflow for automated ideation" \
        "standards/ci-standards.md#8-feature-ideation-feature-ideationyml-bmad-method-repos"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: Action SHA pinning
# ---------------------------------------------------------------------------
check_action_pinning() {
  local repo="$1"

  # List workflow files
  local workflows
  workflows=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")

  for wf in $workflows; do
    [[ "$wf" != *.yml && "$wf" != *.yaml ]] && continue

    local content
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$decoded" ] && continue

    # Find uses: directives that are NOT SHA-pinned
    # SHA-pinned: uses: owner/action@<40+ hex chars>
    # Exclude docker:// and ./ references
    local unpinned
    unpinned=$(echo "$decoded" | grep -E '^\s*-?\s*uses:\s+[^#]*@' | grep -vE '@[0-9a-f]{40}' | grep -vE '(docker://|\.\/)' || true)

    if [ -n "$unpinned" ]; then
      local count
      count=$(echo "$unpinned" | wc -l | tr -d ' ')
      local examples
      examples=$(echo "$unpinned" | head -3 | sed 's/^[[:space:]]*//' | paste -sd ', ' -)
      add_finding "$repo" "action-pinning" "unpinned-actions-$wf" "error" \
        "Workflow \`$wf\` has $count action(s) not pinned to SHA: $examples" \
        "standards/ci-standards.md#action-pinning-policy"
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: Reusable workflow path syntax
# ---------------------------------------------------------------------------
# NOTE: The correct pattern IS combsmith/.github/.github/workflows/...
# because the first .github is the repository name, and the second .github
# is the directory path within that repository. This check is disabled as
# a known false positive per combsmith/.github standards.
#
# Reference: https://docs.github.com/en/actions/using-workflows/reusing-workflows
# Example: uses: combsmith/.github/.github/workflows/claude-code-reusable.yml@v1
check_reusable_workflow_paths() {
  local repo="$1"
  # This check is intentionally disabled — the double .github/ pattern is correct
  return 0
}

# ---------------------------------------------------------------------------
# Check: Dependabot configuration
# ---------------------------------------------------------------------------
check_dependabot_config() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/dependabot.yml" --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "dependabot" "missing-config" "error" \
      "Missing \`.github/dependabot.yml\` configuration file" \
      "standards/dependabot-policy.md"
    return
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  # Check github-actions ecosystem entry exists
  # Accept both double-quoted ("github-actions") and single-quoted ('github-actions') YAML values.
  if ! echo "$decoded" | grep -qE "package-ecosystem:[[:space:]]*(\"github-actions\"|'github-actions')"; then
    add_finding "$repo" "dependabot" "missing-github-actions-ecosystem" "error" \
      "Dependabot config missing \`github-actions\` ecosystem entry" \
      "standards/dependabot-policy.md#github-actions-all-repos"
  fi

  # Check that app ecosystem entries use open-pull-requests-limit: 0
  # Extract ecosystem blocks and check limits.
  # Accept both double-quoted and single-quoted YAML string values.
  for eco in npm pip gomod cargo terraform; do
    if echo "$decoded" | grep -qE "package-ecosystem:[[:space:]]*(\"$eco\"|'$eco')"; then
      # Check if this ecosystem has limit: 0
      # Simple heuristic: find the ecosystem line and look for limit in the next ~10 lines
      local block
      block=$(echo "$decoded" | awk "/package-ecosystem:.*(\"$eco\"|'$eco')/{found=1} found{print; if(/package-ecosystem:/ && NR>1 && !/(\"$eco\"|'$eco')/) exit}" | head -15)
      local limit
      limit=$(echo "$block" | grep 'open-pull-requests-limit:' | head -1 | grep -oE '[0-9]+' || echo "")
      if [ -n "$limit" ] && [ "$limit" != "0" ]; then
        add_finding "$repo" "dependabot" "wrong-limit-$eco" "warning" \
          "Dependabot \`$eco\` ecosystem has \`open-pull-requests-limit: $limit\` (should be \`0\` for security-only policy)" \
          "standards/dependabot-policy.md#policy"
      fi
    fi
  done

  # Check for required labels in dependabot config.
  # Accept both double-quoted and single-quoted YAML string values.
  if ! echo "$decoded" | grep -qE '("security"|'"'"'security'"'"')'; then
    add_finding "$repo" "dependabot" "missing-security-label" "warning" \
      "Dependabot config missing \`security\` label on updates" \
      "standards/dependabot-policy.md#policy"
  fi
  if ! echo "$decoded" | grep -qE '("dependencies"|'"'"'dependencies'"'"')'; then
    add_finding "$repo" "dependabot" "missing-dependencies-label" "warning" \
      "Dependabot config missing \`dependencies\` label on updates" \
      "standards/dependabot-policy.md#policy"
  fi
}

# ---------------------------------------------------------------------------
# Check: Repository settings
# ---------------------------------------------------------------------------
check_repo_settings() {
  local repo="$1"
  local repo_json="$2"

  local settings
  settings=$(echo "$repo_json" | jq '{
    allow_auto_merge: .allow_auto_merge,
    delete_branch_on_merge: .delete_branch_on_merge,
    has_wiki: .has_wiki,
    has_discussions: .has_discussions,
    default_branch: .default_branch,
    has_issues: .has_issues
  }' 2>/dev/null || echo "{}")

  [ "$settings" = "{}" ] && return

  # Boolean settings checks
  for entry in "${REQUIRED_SETTINGS_BOOL[@]}"; do
    IFS=':' read -r key expected severity detail <<< "$entry"
    local actual
    actual=$(echo "$settings" | jq -r ".$key | if . == null then \"null\" else tostring end")
    if [ "$actual" != "$expected" ]; then
      add_finding "$repo" "settings" "$key" "$severity" \
        "$detail (current: \`$actual\`, expected: \`$expected\`)" \
        "standards/github-settings.md#repository-settings--standard-defaults"
    fi
  done

  # Default branch
  local default_branch
  default_branch=$(echo "$settings" | jq -r '.default_branch')
  if [ "$default_branch" != "main" ]; then
    add_finding "$repo" "settings" "default-branch" "error" \
      "Default branch is \`$default_branch\`, should be \`main\`" \
      "standards/github-settings.md#general"
  fi

}

# ---------------------------------------------------------------------------
# Check: Required labels
# ---------------------------------------------------------------------------
check_labels() {
  local repo="$1"

  local existing_labels
  existing_labels=$(gh_api "repos/$ORG/$repo/labels" --jq '.[].name' --paginate 2>/dev/null || echo "")

  for spec in "${REQUIRED_LABEL_SPECS[@]}"; do
    IFS=':' read -r label color description <<< "$spec"
    if ! echo "$existing_labels" | grep -qx "$label"; then
      if [ "$DRY_RUN" = "true" ]; then
        add_finding "$repo" "labels" "missing-label-$label" "warning" \
          "Required label \`$label\` is missing" \
          "standards/github-settings.md#labels--standard-set"
      else
        info "Auto-creating missing label '$label' on $repo"
        if gh label create "$label" \
            --repo "$ORG/$repo" \
            --color "$color" \
            --description "$description" \
            --force 2>/dev/null; then
          info "Label '$label' created successfully on $repo"
        else
          warn "Failed to create label '$label' on $repo — filing finding for manual remediation"
          add_finding "$repo" "labels" "missing-label-$label" "warning" \
            "Required label \`$label\` is missing and could not be auto-created" \
            "standards/github-settings.md#labels--standard-set"
        fi
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: Repository rulesets
# ---------------------------------------------------------------------------
check_rulesets() {
  local repo="$1"

  local rulesets
  rulesets=$(gh_api "repos/$ORG/$repo/rulesets" --jq '.[].name' 2>/dev/null || echo "")

  if ! echo "$rulesets" | grep -qx "pr-quality"; then
    add_finding "$repo" "rulesets" "missing-pr-quality" "error" \
      "Missing \`pr-quality\` repository ruleset" \
      "standards/github-settings.md#pr-quality--standard-ruleset-all-repositories"
  fi

  if ! echo "$rulesets" | grep -qx "code-quality"; then
    add_finding "$repo" "rulesets" "missing-code-quality" "error" \
      "Missing \`code-quality\` repository ruleset (required status checks)" \
      "standards/github-settings.md#code-quality--required-checks-ruleset-all-repositories"
  fi
}

# ---------------------------------------------------------------------------
# Check: CODEOWNERS
# ---------------------------------------------------------------------------
check_codeowners() {
  local repo="$1"

  # CODEOWNERS can be in root, .github/, or docs/
  local found=false
  local codeowners_content=""
  for path in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
    # Use || echo "" so a 404 is non-fatal under set -euo pipefail
    local content
    content=$(gh_api "repos/$ORG/$repo/contents/$path" --jq '.content' 2>/dev/null || echo "")
    if [ -n "$content" ]; then
      found=true
      codeowners_content=$(echo "$content" | base64 -d 2>/dev/null || echo "$content")
      break
    fi
  done

  if [ "$found" = false ]; then
    add_finding "$repo" "settings" "missing-codeowners" "error" \
      "No \`CODEOWNERS\` file found — required for code owner review enforcement (pr-quality ruleset)" \
      "standards/codeowners-standard.md"
    return
  fi

  # Extract non-comment, non-blank owner lines for accurate matching.
  # Each such line has the form: <pattern> <owner1> [<owner2> ...]
  # Standard (codeowners-standard.md):
  #   1. @combsmith/org-leads MUST be the FIRST owner on every line.
  #   2. Additional teams (@combsmith/<slug>) are allowed.
  #   3. Individual users (@username without "/") are forbidden.
  local owner_lines
  owner_lines=$(echo "$codeowners_content" | grep -v '^\s*#' | grep -v '^\s*$')

  if [ -z "$owner_lines" ]; then
    add_finding "$repo" "settings" "codeowners-empty" "error" \
      "CODEOWNERS file has no owner lines (only comments/blank)" \
      "standards/codeowners-standard.md"
    return
  fi

  # Rule 1: @combsmith/org-leads MUST be the first owner on every line
  # (the first whitespace-separated token after the pattern).
  local bad_first_owner=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # awk $2 = first owner token after the pattern
    local first_owner
    first_owner=$(echo "$line" | awk '{print $2}')
    if [ "$first_owner" != "@combsmith/org-leads" ]; then
      bad_first_owner="$line"
      break
    fi
  done <<< "$owner_lines"
  if [ -n "$bad_first_owner" ]; then
    add_finding "$repo" "settings" "codeowners-org-leads-not-first" "error" \
      "CODEOWNERS owner lines must list \`@combsmith/org-leads\` as the FIRST owner. Offending line: \`$bad_first_owner\`" \
      "standards/codeowners-standard.md"
  fi

  # Rule 3: no individual users — every owner token must be a team (contain "/").
  # Collect owner tokens from all lines (everything starting with @).
  local individual_owners
  individual_owners=$(echo "$owner_lines" \
    | tr ' \t' '\n' \
    | grep -E '^@' \
    | grep -vE '^@[^/]+/' \
    | sort -u || true)
  if [ -n "$individual_owners" ]; then
    local joined
    joined=$(echo "$individual_owners" | tr '\n' ' ')
    add_finding "$repo" "settings" "codeowners-individual-users" "error" \
      "CODEOWNERS contains forbidden individual user owners: ${joined% } — only teams (@combsmith/<slug>) are allowed; manage membership via teams" \
      "standards/codeowners-standard.md"
  fi

  # Advisory: a catch-all `*` pattern should exist so files unmatched by any
  # path-specific rule still have an owner.
  if ! echo "$owner_lines" | awk '{print $1}' | grep -qxF '*'; then
    add_finding "$repo" "settings" "codeowners-no-catchall" "warning" \
      "CODEOWNERS has no default \`*\` catch-all pattern — files not matched by a path rule will have no owner and \`require_code_owner_review\` will not apply to them" \
      "standards/codeowners-standard.md"
  fi
}

# ---------------------------------------------------------------------------
# Check: SonarCloud project properties
# ---------------------------------------------------------------------------
check_sonarcloud() {
  local repo="$1"

  # Only check if sonarcloud.yml exists
  if gh_api "repos/$ORG/$repo/contents/.github/workflows/sonarcloud.yml" --jq '.name' > /dev/null 2>&1; then
    if ! gh_api "repos/$ORG/$repo/contents/sonar-project.properties" --jq '.name' > /dev/null 2>&1; then
      add_finding "$repo" "ci-workflows" "missing-sonar-properties" "warning" \
        "SonarCloud workflow exists but \`sonar-project.properties\` is missing" \
        "standards/ci-standards.md#3-sonarcloud-analysis-sonarcloudyml"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: CodeQL default setup is configured (and no stray codeql.yml exists)
#
# After combsmith/.github#103, CodeQL is configured via GitHub's
# managed default setup, not a per-repo workflow file. Two distinct findings:
#
#   1. codeql-default-setup-not-configured (error): the repo has not enabled
#      default setup. Remediate by running:
#        gh api -X PATCH repos/<org>/<repo>/code-scanning/default-setup \
#          -F state=configured -F query_suite=default
#      (or by running scripts/apply-repo-settings.sh against the repo).
#
#   2. stray-codeql-workflow (error): the repo still ships a codeql.yml
#      workflow file. Default setup and an inline workflow are mutually
#      exclusive at the GitHub level — leaving the file behind double-bills
#      CI minutes and creates two competing analyses. Remediation: delete
#      .github/workflows/codeql.yml.
# ---------------------------------------------------------------------------
check_codeql_default_setup() {
  local repo="$1"

  # Query the default-setup state. The endpoint returns 200 with a JSON body
  # describing the state, OR a 4xx if the repo has no code scanning capability
  # (e.g. private without GHAS, archived). Treat any non-"configured" state
  # as a finding so the audit surfaces what needs remediation.
  local state
  state=$(gh_api "repos/$ORG/$repo/code-scanning/default-setup" --jq '.state' 2>/dev/null || echo "")

  if [ "$state" != "configured" ]; then
    local detail
    if [ -z "$state" ]; then
      detail="CodeQL default setup query returned no state — either the repo has code scanning disabled or the API call failed. Enable via \`gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default\`."
    else
      detail="CodeQL default setup is in state \`$state\` (expected \`configured\`). Run \`apply-repo-settings.sh $repo\` or \`gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default\`."
    fi
    add_finding "$repo" "ci-workflows" "codeql-default-setup-not-configured" "error" \
      "$detail" \
      "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
  fi

  # Stray workflow check: any codeql.yml under .github/workflows is drift.
  if gh_api "repos/$ORG/$repo/contents/.github/workflows/codeql.yml" --jq '.name' > /dev/null 2>&1; then
    add_finding "$repo" "ci-workflows" "stray-codeql-workflow" "error" \
      "Repo still ships \`.github/workflows/codeql.yml\`. The org standard now uses GitHub-managed CodeQL default setup; per-repo workflow files are drift and run a duplicate analysis alongside default setup. Delete the file. If a documented exception applies (custom query pack, build mode, path filters), open a standards PR against \`standards/ci-standards.md\` to record the exception before re-adding the workflow." \
      "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
  fi
}

# ---------------------------------------------------------------------------
# Check: Workflow permissions follow least-privilege
# ---------------------------------------------------------------------------
check_workflow_permissions() {
  local repo="$1"

  local workflows
  workflows=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")

  for wf in $workflows; do
    [[ "$wf" != *.yml && "$wf" != *.yaml ]] && continue

    local content
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$decoded" ] && continue

    # Skip reusable workflows (workflow_call-only triggers).
    # Their permissions are controlled entirely by the caller workflow, so
    # requiring a top-level permissions: block here would be redundant and
    # would generate false positives for every *-reusable.yml in the org.
    # All reusable workflows follow the -reusable.yml naming convention.
    if [[ "$wf" == *-reusable.yml || "$wf" == *-reusable.yaml ]]; then
      continue
    fi

    # Check if the workflow has a top-level permissions key
    # Single-job workflows may define permissions at job level instead
    if ! echo "$decoded" | grep -qE '^permissions:'; then
      # Count jobs and check if the single job has job-level permissions
      local job_count
      job_count=$(echo "$decoded" | grep -cE '^  [a-zA-Z_-]+:$' || echo "0")
      local has_job_perms
      has_job_perms=$(echo "$decoded" | grep -cE '^    permissions:' || echo "0")
      if [ "$job_count" -gt 1 ] || [ "$has_job_perms" -eq 0 ]; then
        add_finding "$repo" "ci-workflows" "missing-permissions-$wf" "warning" \
          "Workflow \`$wf\` missing top-level \`permissions:\` declaration (least-privilege policy)" \
          "standards/ci-standards.md#permissions-policy"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: claude.yml jobs both have a checkout step
# ---------------------------------------------------------------------------
check_claude_workflow_checkout() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/claude.yml" --jq '.content' 2>/dev/null || echo "")
  [ -z "$content" ] && return  # missing workflow is caught by check_required_workflows

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return

  # For each job that uses claude-code-action, verify a checkout step precedes it.
  # Strategy: scan for job blocks and check each for 'actions/checkout'.
  for job in claude claude-issue; do
    # Extract the block starting at the job definition
    local job_block
    job_block=$(echo "$decoded" | awk "/^  ${job}:/{found=1} found{print; if(/^  [a-zA-Z_-]+:/ && !/^  ${job}:/) exit}" )
    if [ -z "$job_block" ]; then
      continue  # job not present (e.g. repo only has one job)
    fi

    if ! echo "$job_block" | grep -q 'actions/checkout'; then
      add_finding "$repo" "ci-workflows" "claude-job-missing-checkout-${job}" "error" \
        "The \`${job}\` job in \`claude.yml\` is missing a checkout step — claude-code-action requires the repo to be checked out to read \`CLAUDE.md\` and \`AGENTS.md\`" \
        "standards/workflows/claude.yml"
    fi
  done

  # Verify the check_run trigger is present — without it the claude-ci-fix job
  # in the reusable can never fire to diagnose and fix CI failures on PRs.
  if ! echo "$decoded" | grep -qE "^[[:space:]]+check_run:"; then
    add_finding "$repo" "ci-workflows" "claude-missing-check-run-trigger" "warning" \
      "The \`claude.yml\` workflow is missing the \`check_run\` trigger. Without it the \`claude-ci-fix\` job cannot respond to CI failures on PRs automatically. Add \`check_run: types: [completed]\` to the \`on:\` block." \
      "standards/ci-standards.md#4-claude-code-claudeyml"
  fi
}

# ---------------------------------------------------------------------------
# Check: Tier 1 centralized workflows must be thin caller stubs pinned to @v1
#
# For each workflow that the org has centralized into a reusable workflow,
# verify the downstream repo's copy is a stub that delegates via:
#   uses: combsmith/.github/.github/workflows/<reusable>.yml@v1
#
# This prevents drift: a repo that copies the inline pre-centralization
# version (or pins to @main, or pins to an older tag) is flagged so it
# can be re-synced from the standard. The central .github repo itself is
# exempt because it owns the reusables and may legitimately reference
# its own workflows by @main during release prep.
# ---------------------------------------------------------------------------
check_centralized_workflow_stubs() {
  local repo="$1"

  # The .github repo is the source of truth and is allowed to reference its
  # own reusables by @main; skip the stub check for it.
  [ "$repo" = ".github" ] && return

  # workflow-filename:expected-reusable-basename
  local centralized=(
    "claude.yml:claude-code-reusable"
    "auto-rebase.yml:auto-rebase-reusable"
    "dependency-audit.yml:dependency-audit-reusable"
    "dependabot-automerge.yml:dependabot-automerge-reusable"
    "dependabot-rebase.yml:dependabot-rebase-reusable"
    "agent-shield.yml:agent-shield-reusable"
    "feature-ideation.yml:feature-ideation-reusable"
    "pr-review-mention.yml:pr-review-mention-reusable"
  )

  # List the repo's workflow directory once instead of probing each file.
  # If the listing fails (no workflows dir), there's nothing to check.
  local workflow_list
  workflow_list=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")
  [ -z "$workflow_list" ] && return

  local entry wf reusable
  for entry in "${centralized[@]}"; do
    IFS=':' read -r wf reusable <<< "$entry"

    # Skip workflows that don't exist in this repo. Required workflows are
    # checked separately by check_required_workflows; conditional ones
    # (dependabot-rebase, feature-ideation) are intentionally optional.
    if ! echo "$workflow_list" | grep -qxF "$wf"; then
      continue
    fi

    local content
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$decoded" ] && continue

    # Required pattern: a non-comment line whose `uses:` value is exactly
    # combsmith/.github/.github/workflows/<reusable>.yml@v1
    # Anchor to start-of-line + optional indent so a `# uses: ...` comment
    # cannot satisfy the check.
    local expected="combsmith/\\.github/\\.github/workflows/${reusable}\\.yml@v1"

    if echo "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*${expected}([[:space:]]|$)"; then
      continue  # stub is correctly pinned to @v1 — compliant
    fi

    # Determine why it's non-compliant for a more actionable message.
    local why
    if echo "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*combsmith/\\.github/\\.github/workflows/${reusable}\\.yml@"; then
      why="references the reusable but is not pinned to \`@v1\` (org standard)"
    elif echo "$decoded" | grep -qF "combsmith/.github/.github/workflows/${reusable}"; then
      why="references the reusable but the \`uses:\` line does not match the canonical stub"
    else
      why="is an inline copy instead of a thin caller stub — re-sync from \`standards/workflows/${wf}\`"
    fi

    add_finding "$repo" "ci-workflows" "non-stub-$wf" "error" \
      "Centralized workflow \`$wf\` $why. Replace with the canonical stub from \`standards/workflows/${wf}\` which delegates to \`combsmith/.github/.github/workflows/${reusable}.yml@v1\`." \
      "standards/ci-standards.md#centralization-tiers"
  done
}

# ---------------------------------------------------------------------------
# Check: required-status-check rulesets reference current names
#
# After centralizing workflows into reusables (#87, #88), GitHub composes
# check names as `<caller-job-id> / <reusable-job-id-or-name>`. Repos
# that updated their workflow files but didn't update their rulesets
# are silently broken — the merge gate references a name that no
# longer exists, so it can never be satisfied.
#
# Inspects both the new ruleset system and classic branch protection.
# Flags two distinct problems:
#   1. Stale pre-centralization name (e.g. `claude`, `AgentShield`)
#      → emit "stale-required-check-<old-name>"
#   2. `claude-code / claude` listed as required
#      → emit "required-claude-code-check-broken" because that check
#        is structurally incompatible with workflow-modifying PRs
#        (claude-code-action's app-token validation refuses to mint
#        a token whenever the PR diff includes any workflow file)
# ---------------------------------------------------------------------------
check_centralized_check_names() {
  local repo="$1"

  # The .github repo owns the reusables; its own ruleset is allowed to
  # reference whatever check names it likes.
  [ "$repo" = ".github" ] && return

  # Map from stale name → current canonical name. Used for the rename
  # remediation message. The remediation here is "rename in the
  # ruleset" because both the old and new names refer to a check that
  # CAN be required (it runs on PRs and reports a definitive result).
  #
  # NOTE: `claude` and `claude-issue` are deliberately NOT in this map.
  # The post-centralization equivalents are `claude-code / claude` and
  # `claude-code / claude-issue`, but those checks are themselves
  # incompatible with workflow-modifying PRs (claude-code-action's app
  # token validation refuses to mint a token for any PR whose diff
  # includes a workflow file, so the check fails on every workflow PR
  # and the merge gate becomes a deadlock). The remediation for the
  # `claude*` cases is therefore "remove from required checks", not
  # "rename" — handled below as a separate finding so the message
  # never recommends a name that creates a new deadlock.
  local renames=(
    "AgentShield:agent-shield / AgentShield"
    "Detect ecosystems:dependency-audit / Detect ecosystems"
  )

  # Patterns for required checks that are structurally broken and
  # should be removed (not renamed). Matched as either:
  #   - the bare legacy name ("claude" / "claude-issue"), or
  #   - any reusable-workflow check whose suffix is "/ claude" or
  #     "/ claude-issue", regardless of caller-job-id prefix
  #     (so a custom caller named e.g. "Claude Code / claude" is
  #     also caught, not just the canonical "claude-code / claude").
  #
  # The match is computed against each context line below.

  # Collect every required-status-check context from every source.
  # Sources: (1) every active ruleset, (2) classic branch protection.
  local contexts=""

  # Source 1: rulesets that apply to main
  local ruleset_contexts
  ruleset_contexts=$(gh_api "repos/$ORG/$repo/rules/branches/main" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null || echo "")
  contexts+="$ruleset_contexts"$'\n'

  # Source 2: classic branch protection (may not exist)
  local classic_contexts
  classic_contexts=$(gh_api "repos/$ORG/$repo/branches/main/protection/required_status_checks" \
    --jq '.contexts[]' 2>/dev/null || echo "")
  contexts+="$classic_contexts"

  [ -z "$(echo "$contexts" | tr -d '[:space:]')" ] && return

  # Check 1: stale pre-centralization names that have a safe rename
  local entry old new
  for entry in "${renames[@]}"; do
    IFS=':' read -r old new <<< "$entry"
    if echo "$contexts" | grep -qxF "$old"; then
      add_finding "$repo" "rulesets" "stale-required-check-${old// /-}" "error" \
        "Required-status-check ruleset references the stale check name \`$old\`. After workflow centralization (combsmith/.github#87) this check is published as \`$new\`. Update the ruleset (and any classic branch protection) to use the new name." \
        "standards/ci-standards.md#centralization-tiers"
    fi
  done

  # Check 2: claude-* checks (legacy or post-centralization) listed as
  # required. These cannot be made compliant by renaming because the
  # post-centralization name is itself broken — the only safe action
  # is to remove the check from required-status-checks entirely.
  #
  # We classify each context line by suffix so any caller-job-id prefix
  # is caught (e.g. "claude-code / claude", "Claude Code / claude",
  # "review-claude / claude" all match).
  local context match_type
  while IFS= read -r context; do
    [ -z "$context" ] && continue
    match_type=""
    case "$context" in
      "claude")              match_type="claude" ;;
      "claude-issue")        match_type="claude-issue" ;;
      *"/ claude")           match_type="claude" ;;
      *"/ claude-issue")     match_type="claude-issue" ;;
      *) continue ;;
    esac

    # Stable check id per match type so findings don't churn across
    # audit runs from variations in caller-job-id prefixes.
    local check_id
    if [ "$match_type" = "claude-issue" ]; then
      check_id="required-claude-issue-check-broken"
    else
      check_id="required-claude-check-broken"
    fi

    add_finding "$repo" "rulesets" "$check_id" "error" \
      "Required-status-check ruleset includes \`$context\`, which is incompatible with workflow-modifying PRs. claude-code-action's GitHub App refuses to mint an OAuth token for any PR whose diff includes a workflow file, so the check fails on every workflow PR and the merge gate becomes a deadlock. **Remove \`$context\` from required status checks** — do NOT rename it. The Claude review check still runs on normal PRs and surfaces feedback without being a merge gate. See \`scripts/apply-rulesets.sh\` (post combsmith/.github#94) for the canonical required-checks list." \
      "standards/ci-standards.md#centralization-tiers"
  done <<< "$contexts"
}

# ---------------------------------------------------------------------------
# Check: CLAUDE.md exists and references AGENTS.md
# ---------------------------------------------------------------------------
check_claude_md() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/CLAUDE.md" --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-claude-md" "error" \
      "Missing \`CLAUDE.md\` — every repo must have a CLAUDE.md that references AGENTS.md" \
      "AGENTS.md"
    return
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  if ! echo "$decoded" | grep -qi 'AGENTS\.md'; then
    add_finding "$repo" "standards" "claude-md-missing-agents-ref" "error" \
      "\`CLAUDE.md\` does not reference \`AGENTS.md\`" \
      "AGENTS.md"
  fi
}

# ---------------------------------------------------------------------------
# Check: AGENTS.md exists and references org .github/AGENTS.md
# ---------------------------------------------------------------------------
check_agents_md() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/AGENTS.md" --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-agents-md" "error" \
      "Missing \`AGENTS.md\` — every repo must have an AGENTS.md that references the org-level standards" \
      "AGENTS.md"
    return
  fi

  # For repos other than .github, AGENTS.md should reference the org-level .github/AGENTS.md
  if [ "$repo" != ".github" ]; then
    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

    # Accept two forms of reference:
    #   1. Any path containing .github/AGENTS.md (relative link text or path reference)
    #   2. GitHub blob URL format: /combsmith/.github/blob/<ref>/AGENTS.md (in href)
    # Both are treated as references to the org-level standards file.
    if ! echo "$decoded" | grep -qE '(\.github/AGENTS\.md|combsmith/\.github/blob/.+/AGENTS\.md)'; then
      add_finding "$repo" "standards" "agents-md-missing-org-ref" "error" \
        "\`AGENTS.md\` does not reference the org-level \`.github/AGENTS.md\` standards" \
        "AGENTS.md"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: check-suite auto-trigger disabled for Claude and CodeRabbit
# ---------------------------------------------------------------------------
check_check_suite_prefs() {
  local repo="$1"

  local prefs
  prefs=$(gh_api "repos/$ORG/$repo/check-suites/preferences" 2>/dev/null || true)
  if [ -z "$prefs" ]; then
    add_finding "$repo" "settings" "check-suite-prefs-unreadable" "warning" \
      "Could not read check-suite preferences — verify GH_TOKEN has repo scope and the repo is accessible. Check-suite auto-trigger compliance was not evaluated." \
      "standards/github-settings.md"
    return
  fi

  for app_id in "${CHECK_SUITE_APP_IDS[@]}"; do
    local setting
    setting=$(echo "$prefs" | jq -r --argjson id "$app_id" \
      '.preferences.auto_trigger_checks // [] | map(select(.app_id == $id)) | first | .setting // "missing"')

    # "missing" means the app has never run in this repo — no orphaned suite possible
    [ "$setting" = "missing" ] && continue
    [ "$setting" = "false"   ] && continue

    local app_label="app_id=$app_id"
    [ "$app_id" = "1236702" ] && app_label="Claude (1236702)"
    [ "$app_id" = "347564"  ] && app_label="CodeRabbit (347564)"

    add_finding "$repo" "settings" "check-suite-auto-trigger-${app_id}" "error" \
      "$app_label auto-trigger is enabled: GitHub creates a queued check suite on every push that is never completed, permanently blocking auto-merge. Run: \`bash scripts/apply-repo-settings.sh $repo\`" \
      "standards/github-settings.md"
  done
}

# ---------------------------------------------------------------------------
# Issue management
# ---------------------------------------------------------------------------
ensure_audit_label() {
  local repo="$1"
  gh label create "$AUDIT_LABEL" \
    --repo "$ORG/$repo" \
    --description "$AUDIT_LABEL_DESC" \
    --color "$AUDIT_LABEL_COLOR" \
    --force 2>/dev/null || true
  gh label create "claude" \
    --repo "$ORG/$repo" \
    --description "For Claude agent pickup" \
    --color "8B5CF6" \
    --force 2>/dev/null || true
}

# Create all required labels (idempotent — uses --force to update if present)
ensure_required_labels() {
  local repo="$1"
  # Format: "name|color|description" (pipe-delimited to avoid colon conflicts)
  local label_configs=(
    "security|d93f0b|Security-related PRs and issues"
    "dependencies|0075ca|Dependency update PRs"
    "scorecard|d93f0b|OpenSSF Scorecard findings"
    "bug|d73a4a|Bug reports"
    "enhancement|a2eeef|Feature requests"
    "documentation|0075ca|Documentation changes"
    "in-progress|fbca04|An agent is actively working this issue"
  )

  for config in "${label_configs[@]}"; do
    IFS='|' read -r name color description <<< "$config"
    gh label create "$name" \
      --repo "$ORG/$repo" \
      --description "$description" \
      --color "$color" \
      --force 2>/dev/null || true
  done
}

create_issue_for_finding() {
  local repo="$1" category="$2" check="$3" severity="$4" detail="$5" standard_ref="$6"

  local title="Compliance: ${check}"
  # Normalize title for search
  local search_title="${title}"

  # Check for existing open issue with same title
  local existing
  existing=$(gh issue list --repo "$ORG/$repo" \
    --label "$AUDIT_LABEL" \
    --state open \
    --search "\"$search_title\" in:title" \
    --json number,title \
    -q ".[] | select(.title == \"$search_title\") | .number" \
    2>/dev/null | head -1 || echo "")

  if [ -n "$existing" ]; then
    # Update existing issue with a comment
    gh issue comment "$existing" --repo "$ORG/$repo" \
      --body "**Weekly Compliance Audit** ($(date -u +%Y-%m-%d))

This finding is still open.

**Detail:** $detail

**Standard:** [$standard_ref](https://github.com/$ORG/.github/blob/main/$standard_ref)" 2>/dev/null || true
    # Ensure claude label is present on pre-existing issues
    gh issue edit "$existing" --repo "$ORG/$repo" --add-label "claude" 2>/dev/null || true
    info "Updated existing issue #$existing in $repo for: $check"
    # Record existing issue for umbrella
    jq --null-input \
      --arg repo "$repo" \
      --arg category "$category" \
      --arg check "$check" \
      --arg number "$existing" \
      --arg url "https://github.com/$ORG/$repo/issues/$existing" \
      '{repo:$repo,category:$category,check:$check,number:$number,url:$url}' \
      >> "$ISSUES_FILE"
    return
  fi

  # Build issue body — variable values are safe (from our own check logic + GitHub API)
  local body="## Compliance Finding

**Category:** \`${category}\`
**Severity:** \`${severity}\`
**Check:** \`${check}\`

## Detail

${detail}

## Standard Reference

[${standard_ref}](https://github.com/${ORG}/.github/blob/main/${standard_ref})

## Remediation

Please review the linked standard and bring this repository into compliance.

See the [full standards documentation](https://github.com/${ORG}/.github/tree/main/standards) for implementation guidance.

---
*This issue was automatically created by the [weekly compliance audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/compliance-audit.yml).*"

  local issue_url
  # Individual finding issues get both compliance-audit and claude labels so agents can pick them up.
  issue_url=$(gh issue create --repo "$ORG/$repo" \
    --title "$search_title" \
    --label "$AUDIT_LABEL" \
    --label "claude" \
    --body "$body" 2>/dev/null || echo "")

  if [ -n "$issue_url" ]; then
    local new_issue
    new_issue=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
    info "Created issue #$new_issue in $repo for: $check ($issue_url)"

    # Record created issue for umbrella
    if [ -n "$new_issue" ]; then
      jq --null-input \
        --arg repo "$repo" \
        --arg category "$category" \
        --arg check "$check" \
        --arg number "$new_issue" \
        --arg url "$issue_url" \
        '{repo:$repo,category:$category,check:$check,number:$number,url:$url}' \
        >> "$ISSUES_FILE"
    fi
  else
    warn "Failed to create issue in $repo for: $check"
  fi
}

create_umbrella_issue() {
  local audit_date
  audit_date=$(date -u +%Y-%m-%d)
  local title="Compliance audit — $audit_date"

  # Skip if no findings
  local total_findings
  total_findings=$(jq length "$FINDINGS_FILE")
  if [ "$total_findings" -eq 0 ]; then
    info "No findings — skipping umbrella issue"
    return
  fi

  # Check for existing open umbrella issue for today
  local existing_umbrella
  existing_umbrella=$(gh issue list --repo "$ORG/.github" \
    --label "$AUDIT_LABEL" \
    --state open \
    --search "\"$title\" in:title" \
    --json number,title \
    -q ".[] | select(.title == \"$title\") | .number" \
    2>/dev/null | head -1 || echo "")

  if [ -n "$existing_umbrella" ]; then
    info "Umbrella issue #$existing_umbrella already exists for $audit_date — skipping"
    return
  fi

  # Map finding categories to remediation groups
  # Each group: category_keys|display_name|remediation_script
  local groups=(
    "settings|Repository Settings|apply-repo-settings.sh"
    "push-protection|Push Protection & Secret Scanning|apply-repo-settings.sh (security_and_analysis) + per-repo ci.yml and .gitignore"
    "labels|Labels|apply_labels() in apply-repo-settings.sh"
    "rulesets|Repository Rulesets|apply-rulesets.sh"
    "ci-workflows|Workflows|per-repo workflow additions"
    "action-pinning|Action SHA Pinning|pin actions to SHA in each workflow file"
    "dependabot|Dependabot Configuration|per-repo .github/dependabot.yml"
    "standards|CLAUDE.md / AGENTS.md References|per-repo doc updates"
  )

  local body
  body="## Compliance Audit — $audit_date

This umbrella issue tracks all findings from the automated compliance audit run on **$audit_date**.
Findings are grouped by remediation category. Address each category together to avoid duplicate agent PRs.

**Total findings:** $total_findings across $(jq -r '[.[].repo] | unique | length' "$FINDINGS_FILE") repositories

---

## Remediation Work Breakdown
"

  for group_entry in "${groups[@]}"; do
    IFS='|' read -r cat_key display_name remediation_script <<< "$group_entry"

    local cat_findings
    cat_findings=$(jq -c --arg cat "$cat_key" '[.[] | select(.category == $cat)]' "$FINDINGS_FILE")
    local cat_count
    cat_count=$(echo "$cat_findings" | jq 'length')

    [ "$cat_count" -eq 0 ] && continue

    local affected_repos
    affected_repos=$(echo "$cat_findings" | jq -r '[.[].repo] | unique | join(", ")')

    body+="
### $display_name ($cat_count finding(s))

**Remediation:** \`$remediation_script\`
**Affected repos:** $affected_repos

| Repo | Check | Severity |
|------|-------|----------|
"
    # Add per-finding rows with issue links where available
    while IFS= read -r finding; do
      local f_repo f_check f_severity f_number f_url
      f_repo=$(echo "$finding" | jq -r '.repo')
      f_check=$(echo "$finding" | jq -r '.check')
      f_severity=$(echo "$finding" | jq -r '.severity')

      # Look up issue link if we tracked it
      local issue_link=""
      if [ -s "$ISSUES_FILE" ]; then
        local issue_entry
        issue_entry=$(grep -F "\"repo\":\"$f_repo\"" "$ISSUES_FILE" 2>/dev/null | \
          jq -c --arg repo "$f_repo" --arg check "$f_check" \
          'select(.repo == $repo and .check == $check)' 2>/dev/null | head -1 || echo "")
        if [ -n "$issue_entry" ]; then
          f_number=$(echo "$issue_entry" | jq -r '.number')
          f_url=$(echo "$issue_entry" | jq -r '.url')
          issue_link=" ([#$f_number]($f_url))"
        fi
      fi

      body+="| \`$f_repo\` | \`$f_check\`$issue_link | \`$f_severity\` |
"
    done < <(echo "$cat_findings" | jq -c '.[]')

  done

  body+="
---
*Generated by the [weekly compliance audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/compliance-audit.yml) on $(date -u "+%Y-%m-%d %H:%M UTC").*
*Address each remediation category as a single coordinated PR to avoid duplicate agent work.*"

  ensure_audit_label ".github"

  local umbrella_url
  umbrella_url=$(gh issue create --repo "$ORG/.github" \
    --title "$title" \
    --label "$AUDIT_LABEL" \
    --label "claude" \
    --body "$body" 2>/dev/null || echo "")

  if [ -n "$umbrella_url" ]; then
    info "Created umbrella issue: $umbrella_url"
  else
    warn "Failed to create umbrella issue in $ORG/.github"
  fi
}

close_resolved_issues() {
  local repo="$1"

  # Get all open compliance-audit issues
  local open_issues
  open_issues=$(gh issue list --repo "$ORG/$repo" \
    --label "$AUDIT_LABEL" \
    --state open \
    --json number,title \
    -q '.[] | "\(.number)\t\(.title)"' 2>/dev/null || echo "")

  [ -z "$open_issues" ] && return

  # Get current findings for this repo (bail if jq fails to avoid false closures)
  local current_checks
  if ! current_checks=$(jq -r --arg repo "$repo" '.[] | select(.repo == $repo) | .check' "$FINDINGS_FILE" 2>/dev/null); then
    warn "Failed to read findings for $repo — skipping issue closure to avoid false positives"
    return
  fi

  while IFS=$'\t' read -r issue_num issue_title; do
    # Extract the check name from the title "Compliance: <check>"
    local check_name="${issue_title#Compliance: }"

    # If this check is no longer in findings, close the issue
    if ! echo "$current_checks" | grep -qx "$check_name"; then
      gh issue close "$issue_num" --repo "$ORG/$repo" \
        --comment "Resolved! This check is now passing as of $(date -u +%Y-%m-%d). Closing automatically." \
        2>/dev/null || true
      info "Closed resolved issue #$issue_num in $repo: $issue_title"
    fi
  done <<< "$open_issues"
}

# ---------------------------------------------------------------------------
# Summary generation
# ---------------------------------------------------------------------------
generate_summary() {
  local total_repos="$1"
  local total_findings
  total_findings=$(jq length "$FINDINGS_FILE")

  local error_count
  error_count=$(jq '[.[] | select(.severity == "error")] | length' "$FINDINGS_FILE")
  local warning_count
  warning_count=$(jq '[.[] | select(.severity == "warning")] | length' "$FINDINGS_FILE")

  cat > "$SUMMARY_FILE" <<HEREDOC
# Org Compliance Audit Report — $(date -u +%Y-%m-%d)

## Summary

| Metric | Count |
|--------|-------|
| Repositories audited | $total_repos |
| Total findings | $total_findings |
| Errors (must fix) | $error_count |
| Warnings (should fix) | $warning_count |

## Findings by Repository

HEREDOC

  # Group findings by repo
  local repos_with_findings
  repos_with_findings=$(jq -r '[.[].repo] | unique[]' "$FINDINGS_FILE")

  if [ -z "$repos_with_findings" ]; then
    echo "All repositories are fully compliant! No findings." >> "$SUMMARY_FILE"
    return
  fi

  for repo in $repos_with_findings; do
    local repo_findings
    repo_findings=$(jq -r --arg repo "$repo" \
      '.[] | select(.repo == $repo) | "| `\(.severity)` | \(.category) | \(.check) | \(.detail) |"' \
      "$FINDINGS_FILE")

    local repo_count
    repo_count=$(jq --arg repo "$repo" '[.[] | select(.repo == $repo)] | length' "$FINDINGS_FILE")

    cat >> "$SUMMARY_FILE" <<HEREDOC
### [$repo](https://github.com/$ORG/$repo) — $repo_count finding(s)

| Severity | Category | Check | Detail |
|----------|----------|-------|--------|
$repo_findings

HEREDOC
  done

  # Category breakdown
  cat >> "$SUMMARY_FILE" <<HEREDOC
## Findings by Category

HEREDOC

  for category in ci-workflows action-pinning dependabot settings push-protection labels rulesets standards; do
    local cat_count
    cat_count=$(jq --arg cat "$category" '[.[] | select(.category == $cat)] | length' "$FINDINGS_FILE")
    if [ "$cat_count" -gt 0 ]; then
      echo "- **$category:** $cat_count finding(s)" >> "$SUMMARY_FILE"
    fi
  done

  cat >> "$SUMMARY_FILE" <<HEREDOC

---
*Generated by the [weekly compliance audit](https://github.com/$ORG/.github/blob/main/.github/workflows/compliance-audit.yml) on $(date -u "+%Y-%m-%d %H:%M UTC").*
HEREDOC
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # Preflight: verify GH_TOKEN is set and gh CLI is authenticated
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::GH_TOKEN is not set. Ensure ORG_SCORECARD_TOKEN secret is configured and passed as an env var to this step." \
      "Job-level env vars should be inherited, but add GH_TOKEN explicitly to the step env block as a workaround." >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "::error::gh auth failed — GH_TOKEN is set but authentication did not succeed." \
      "Check that ORG_SCORECARD_TOKEN is valid and has repo + read:org scopes." >&2
    exit 1
  fi

  info "Starting compliance audit for $ORG"
  info "Report directory: $REPORT_DIR"
  info "Dry run: $DRY_RUN"

  # Initialize findings and issues tracking files
  echo "[]" > "$FINDINGS_FILE"
  : > "$ISSUES_FILE"

  # Get all non-archived repos in the org
  local repos
  repos=$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)

  if [ -z "$repos" ]; then
    warn "No repositories found in $ORG — check GH_TOKEN permissions"
    echo "[]" > "$FINDINGS_FILE"
    return 1
  fi

  local repo_count=0

  for repo in $repos; do
    repo_count=$((repo_count + 1))
    log "Auditing $ORG/$repo"

    detect_ecosystems "$repo"
    if [ ${#ECOSYSTEMS[@]} -eq 0 ]; then
      info "Detected ecosystems: none"
    else
      info "Detected ecosystems: ${ECOSYSTEMS[*]}"
    fi

    # Fetch full repo JSON once and share with settings/push-protection checks
    local repo_json
    repo_json=$(gh_api "repos/$ORG/$repo" 2>/dev/null || echo "{}")
    if [ "$repo_json" = "{}" ]; then
      add_finding "$repo" "settings" "repo_metadata_unavailable" "error" \
        "Could not fetch repository metadata; settings and push-protection checks were skipped" \
        "standards/github-settings.md#repository-settings--standard-defaults"
      log_end
      continue
    fi

    check_required_workflows "$repo"
    check_action_pinning "$repo"
    check_reusable_workflow_paths "$repo"
    check_dependabot_config "$repo"
    check_repo_settings "$repo" "$repo_json"
    check_labels "$repo"
    check_rulesets "$repo"
    check_codeowners "$repo"
    check_sonarcloud "$repo"
    check_codeql_default_setup "$repo"
    check_workflow_permissions "$repo"
    check_claude_workflow_checkout "$repo"
    check_centralized_workflow_stubs "$repo"
    check_centralized_check_names "$repo"
    check_claude_md "$repo"
    check_agents_md "$repo"
    check_check_suite_prefs "$repo"
    pp_run_all_checks "$repo"

    log_end
  done

  info "Audit complete: $findings_count findings across $repo_count repositories"

  # Generate summary report
  generate_summary "$repo_count"

  # Create/update/close issues
  if [ "$CREATE_ISSUES" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    info "Managing issues..."

    for repo in $repos; do
      ensure_audit_label "$repo"
      ensure_required_labels "$repo"

      # Create issues for new findings (process substitution avoids subshell)
      while IFS= read -r finding; do
        [ -z "$finding" ] && continue
        local f_check f_severity f_detail f_standard_ref f_category
        f_category=$(echo "$finding" | jq -r '.category')
        f_check=$(echo "$finding" | jq -r '.check')
        f_severity=$(echo "$finding" | jq -r '.severity')
        f_detail=$(echo "$finding" | jq -r '.detail')
        f_standard_ref=$(echo "$finding" | jq -r '.standard_ref')

        create_issue_for_finding "$repo" "$f_category" "$f_check" "$f_severity" "$f_detail" "$f_standard_ref"
      done < <(jq -c --arg repo "$repo" '.[] | select(.repo == $repo)' "$FINDINGS_FILE")

      # Close issues for resolved findings
      close_resolved_issues "$repo"
    done

    # Create one umbrella issue per audit run grouping all findings by remediation category.
    # Both individual issues and the umbrella get the `claude` label for agent pickup.
    create_umbrella_issue
  else
    info "Skipping issue creation (DRY_RUN=$DRY_RUN, CREATE_ISSUES=$CREATE_ISSUES)"
  fi

  # Output report paths
  echo "findings=$FINDINGS_FILE"
  echo "summary=$SUMMARY_FILE"

  info "Summary written to $SUMMARY_FILE"
  info "Findings written to $FINDINGS_FILE"

  cat "$SUMMARY_FILE"
}

main "$@"
