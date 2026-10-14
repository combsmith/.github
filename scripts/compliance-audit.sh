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
#   $REPORT_DIR/findings.json      — machine-readable findings
#   $REPORT_DIR/summary.md         — human-readable report
#   $REPORT_DIR/issue-counts.json  — issue management counts (added/existing/removed)
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
ISSUE_COUNTS_FILE="$REPORT_DIR/issue-counts.json"

# Issue management counters (incremented by create_issue_for_finding / close_resolved_issues)
ISSUES_ADDED=0
ISSUES_EXISTING=0
ISSUES_REMOVED=0
ISSUES_RETRIGGERED=0

REQUIRED_WORKFLOWS=(ci.yml sonarcloud.yml dev-lead.yml dependabot-automerge.yml dependency-audit.yml agent-shield.yml pr-review-mention.yml)
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

# escape_ere escapes ERE metacharacters in a string for literal matching in grep -E.
# This ensures that version tags (e.g. v2.1) and reusable basenames are treated
# as literal strings even if they contain regex metacharacters.
escape_ere() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\\/{}]/\\&/g'
}

# Retry wrapper for gh api calls (handles rate limits)
gh_api() {
  local retries=3
  local output
  for i in $(seq 1 $retries); do
    if output=$(gh api "$@" 2>/dev/null); then
      echo "$output"
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

# Shared dev-lead retrigger helpers — dl_dev_lead_active() and
# dl_cycle_trigger_label(). Used to re-engage dev-lead on persistent findings.
# shellcheck source=lib/dev-lead-retrigger.sh
. "$SCRIPT_DIR/lib/dev-lead-retrigger.sh"

# Canary-ring pin model — ring_tier_for_repo(), ring_canonical_ref(),
# ring_legacy_csv(). Shared with deploy-standard-workflows.sh so the audit's
# "non-compliant" and the deploy sweep's "drift" stay in lockstep (#482).
# shellcheck source=lib/ring-pins.sh
. "$SCRIPT_DIR/lib/ring-pins.sh"

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
    # Exclude $ORG/.github reusable workflow refs — these use tag refs
    # (@v1, @v2, @main) by design per ci-standards.md#action-pinning-policy
    local unpinned
    unpinned=$(echo "$decoded" | grep -E '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[^#]*@' | grep -vE '@[0-9a-f]{40}' | grep -vE '(docker://|\.\/)' | grep -vE "uses:[[:space:]]+$ORG/\\.github(-private)?/\\.github/workflows/" || true)

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
    actual=$(printf '%s' "$settings" | jq -r --arg key "$key" '.[$key] | if . == null then "null" else tostring end')
    if [ "$actual" != "$expected" ]; then
      add_finding "$repo" "settings" "$key" "$severity" \
        "$detail (current: \`$actual\`, expected: \`$expected\`)" \
        "standards/github-settings.md#repository-settings--standard-defaults"
    fi
  done

  # Default branch
  local default_branch
  default_branch=$(printf '%s' "$settings" | jq -r '.default_branch')
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
  local repo_json="${2:-}"

  # Default branch drives which rulesets are "targeting main" below.
  local default_branch
  default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"' 2>/dev/null || echo "main")
  if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
    default_branch="main"
  fi

  # Fetch the full ruleset list once (id + name + everything). We need ids to
  # pull each ruleset's bypass_actors below, so we cannot use --jq '.[].name'.
  # Use --paginate so all rulesets are fetched regardless of page count, then
  # reconstitute the per-page arrays into one flat array with jq -s '[.[]]'.
  local rulesets_json
  rulesets_json=$(gh_api --paginate "repos/$ORG/$repo/rulesets" 2>/dev/null | jq -s '[.[][]]' 2>/dev/null || echo "[]")
  [ -z "$rulesets_json" ] && rulesets_json="[]"

  local names
  names=$(echo "$rulesets_json" | jq -r '.[].name' 2>/dev/null || echo "")

  if ! echo "$names" | grep -qx "pr-quality"; then
    add_finding "$repo" "rulesets" "missing-pr-quality" "error" \
      "Missing \`pr-quality\` repository ruleset" \
      "standards/github-settings.md#pr-quality--standard-ruleset-all-repositories"
  fi

  if ! echo "$names" | grep -qx "code-quality"; then
    add_finding "$repo" "rulesets" "missing-code-quality" "error" \
      "Missing \`code-quality\` repository ruleset (required status checks)" \
      "standards/github-settings.md#code-quality--required-checks-ruleset-all-repositories"
  fi

  check_ruleset_bypass_actors "$repo" "$default_branch" "$rulesets_json"
  check_legacy_rulesets "$repo" "$default_branch" "$rulesets_json"
}

# ---------------------------------------------------------------------------
# Check: Ruleset bypass actors (every ruleset targeting the default branch)
# ---------------------------------------------------------------------------
# The standard (github-settings.md § "Bypass Actors — Required on Every Ruleset
# Targeting main") requires that EVERY ruleset whose conditions include the
# default branch grant always-bypass to BOTH:
#   1. the `dependabot-automerge-petry` GitHub App (Integration, actor_id 3167543)
#   2. the `OrganizationAdmin` role
# GitHub evaluates bypass eligibility independently per ruleset, so a missing
# actor on code-quality (or a legacy protect-branches / main ruleset) silently
# blocks Dependabot auto-merge or removes the emergency admin override even when
# pr-quality is correct. This logic previously lived only as a copy-paste shell
# snippet in the standard and was never enforced by the audit.
#
# Two correctness nuances the simple snippet missed:
#   - bypass_mode MUST be `always`. `pull_request` mode only applies when the
#     bypass actor opens the PR; Dependabot opens its own PRs, so a
#     `pull_request`-mode app bypass is rejected at merge time.
#   - The `Repository admin` role (RepositoryRole, actor_id 5) is NOT the
#     `OrganizationAdmin` role. It renders similarly in the UI but is repo-scoped
#     and does not satisfy the org-wide emergency-override requirement.
DEPENDABOT_APP_ACTOR_ID=3167543

check_ruleset_bypass_actors() {
  local repo="$1" default_branch="$2" rulesets_json="$3"

  local std_ref="standards/github-settings.md#bypass-actors--required-on-every-ruleset-targeting-main"

  local ids
  ids=$(echo "$rulesets_json" | jq -r '.[].id' 2>/dev/null || echo "")
  [ -z "$ids" ] && return 0

  local rs_id
  for rs_id in $ids; do
    local rs
    rs=$(gh_api "repos/$ORG/$repo/rulesets/$rs_id" 2>/dev/null || echo "")
    [ -z "$rs" ] && continue

    # Does this ruleset target the default branch? Match the GitHub aliases
    # (~DEFAULT_BRANCH, ~ALL) or an explicit refs/heads/<default> include.
    local targets_default
    targets_default=$(echo "$rs" | jq --arg db "refs/heads/$default_branch" '
      ((.conditions.ref_name.include) // []) as $inc
      | ((.conditions.ref_name.exclude) // []) as $exc
      | (
          (($inc | index("~DEFAULT_BRANCH")) != null)
          or (($inc | index("~ALL")) != null)
          or (($inc | index($db)) != null)
        )
        and (($exc | index("~DEFAULT_BRANCH")) == null)
        and (($exc | index($db)) == null)
    ' 2>/dev/null || echo "false")
    [ "$targets_default" != "true" ] && continue

    local rs_name
    rs_name=$(echo "$rs" | jq -r '.name' 2>/dev/null || echo "ruleset-$rs_id")
    # Stable, filesystem/label-safe slug for the finding id so findings don't
    # churn across runs. Ruleset names (pr-quality, code-quality, …) are stable.
    local slug
    slug=$(printf '%s' "$rs_name" | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9_-')
    [ -z "$slug" ] && slug="$rs_id"

    # --- Bypass actor check (single jq invocation) ------------------------
    local oa_always oa_any repo_admin dep_always dep_any
    local bypass_info
    bypass_info=$(jq -r --argjson id "$DEPENDABOT_APP_ACTOR_ID" '
      [
        ([.bypass_actors[]? | select(.actor_type=="OrganizationAdmin" and .bypass_mode=="always")] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="OrganizationAdmin")] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="RepositoryRole" and .actor_id==5)] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="Integration" and .actor_id==$id and .bypass_mode=="always")] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="Integration" and .actor_id==$id)] | length > 0)
      ] | map(tostring) | join(" ")
    ' <<< "$rs" 2>/dev/null || echo "false false false false false")
    [ -z "$bypass_info" ] && bypass_info="false false false false false"
    read -r oa_always oa_any repo_admin dep_always dep_any <<< "$bypass_info"

    if [ "$oa_always" != "true" ]; then
      if [ "$oa_any" = "true" ]; then
        add_finding "$repo" "rulesets" "ruleset-bypass-orgadmin-mode-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) grants \`OrganizationAdmin\` bypass but not with \`bypass_mode: always\`. The standard requires \`always\` for emergency admin override on every ruleset targeting the default branch." \
          "$std_ref"
      elif [ "$repo_admin" = "true" ]; then
        add_finding "$repo" "rulesets" "ruleset-bypass-orgadmin-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) grants bypass to the **Repository admin** role (RepositoryRole id 5), not the **OrganizationAdmin** role required by the standard. Repository admin is repo-scoped and does not satisfy the org-wide emergency-override requirement. Add \`OrganizationAdmin\` with \`bypass_mode: always\`." \
          "$std_ref"
      else
        add_finding "$repo" "rulesets" "ruleset-bypass-orgadmin-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) is missing the required \`OrganizationAdmin\` bypass actor (\`bypass_mode: always\`) for emergency admin override." \
          "$std_ref"
      fi
    fi

    # --- dependabot-automerge-petry app -----------------------------------
    if [ "$dep_always" != "true" ]; then
      if [ "$dep_any" = "true" ]; then
        add_finding "$repo" "rulesets" "ruleset-bypass-dependabot-mode-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) grants the \`dependabot-automerge-petry\` app (id $DEPENDABOT_APP_ACTOR_ID) bypass but with the wrong mode. \`pull_request\` mode only applies when the bypass actor opens the PR; Dependabot opens its own PRs, so its merge API calls are rejected. Set \`bypass_mode: always\`." \
          "$std_ref"
      else
        add_finding "$repo" "rulesets" "ruleset-bypass-dependabot-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) is missing the required \`dependabot-automerge-petry\` app (id $DEPENDABOT_APP_ACTOR_ID) bypass actor (\`bypass_mode: always\`). Without it, Dependabot auto-merge API calls are rejected by this ruleset — GitHub evaluates bypass per-ruleset, so it must be present on every ruleset targeting the default branch, not only \`pr-quality\`." \
          "$std_ref"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: Legacy / non-sanctioned rulesets on the default branch
# ---------------------------------------------------------------------------
# `pr-quality` and `code-quality` are the ONLY sanctioned rulesets
# (standards/github-settings.md § Repository Rulesets). Classic
# `protect-branches` rules and ad-hoc `main` rulesets are deprecated and MUST be
# migrated into the two sanctioned rulesets and deleted. A leftover legacy
# ruleset is drift: it duplicates protections, and — because GitHub evaluates
# bypass per-ruleset — it is a second place every bypass actor must be kept in
# sync (the exact trap that produced the inconsistent OrganizationAdmin /
# RepositoryAdmin bypass state across the fleet).
#
# Deleting a legacy ruleset is only safe once every required status check it
# carries is ALSO required by a sanctioned ruleset; otherwise deletion silently
# drops a merge gate. This check computes that migration delta and reports it so
# remediation is deterministic: "safe to delete" vs the exact checks to migrate
# first.
SANCTIONED_RULESETS=("pr-quality" "code-quality")

check_legacy_rulesets() {
  local repo="$1" default_branch="$2" rulesets_json="$3"

  local std_ref="standards/github-settings.md#repository-rulesets"

  local ids
  ids=$(echo "$rulesets_json" | jq -r '.[].id' 2>/dev/null || echo "")
  [ -z "$ids" ] && return 0

  # jq snippet: does a ruleset (full JSON on stdin) target the default branch?
  # Kept identical to check_ruleset_bypass_actors so the two agree on scope.
  local targets_jq='
    ((.conditions.ref_name.include) // []) as $inc
    | ((.conditions.ref_name.exclude) // []) as $exc
    | (
        (($inc | index("~DEFAULT_BRANCH")) != null)
        or (($inc | index("~ALL")) != null)
        or (($inc | index($db)) != null)
      )
      and (($exc | index("~DEFAULT_BRANCH")) == null)
      and (($exc | index($db)) == null)
  '

  # Pass 1: fetch every default-branch ruleset once, caching name + JSON, and
  # accumulate the set of status-check contexts required by the SANCTIONED
  # rulesets (the coverage that will remain after a legacy ruleset is deleted).
  local sanctioned_ctx=""        # newline-separated contexts
  declare -A rs_cache=()         # rs_id -> full JSON (only default-branch ones)
  declare -A rs_name_cache=()    # rs_id -> name
  local rs_id rs targets rs_name
  for rs_id in $ids; do
    rs=$(gh_api "repos/$ORG/$repo/rulesets/$rs_id" 2>/dev/null || echo "")
    [ -z "$rs" ] && continue
    targets=$(echo "$rs" | jq --arg db "refs/heads/$default_branch" "$targets_jq" 2>/dev/null || echo "false")
    [ "$targets" != "true" ] && continue

    rs_name=$(echo "$rs" | jq -r '.name' 2>/dev/null || echo "ruleset-$rs_id")
    rs_cache["$rs_id"]="$rs"
    rs_name_cache["$rs_id"]="$rs_name"

    if [[ " ${SANCTIONED_RULESETS[*]} " == *" $rs_name "* ]]; then
      local ctx
      ctx=$(echo "$rs" | jq -r '[.rules[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null || echo "")
      [ -n "$ctx" ] && sanctioned_ctx+="$ctx"$'\n'
    fi
  done

  # Pass 2: flag every non-sanctioned default-branch ruleset and compute the
  # set of required checks it carries that are NOT covered by the sanctioned
  # rulesets — the checks that must be migrated before it is safe to delete.
  for rs_id in "${!rs_cache[@]}"; do
    rs_name="${rs_name_cache[$rs_id]}"
    [[ " ${SANCTIONED_RULESETS[*]} " == *" $rs_name "* ]] && continue

    rs="${rs_cache[$rs_id]}"
    local slug
    slug=$(printf '%s' "$rs_name" | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9_-')
    [ -z "$slug" ] && slug="$rs_id"

    local legacy_ctx uncovered=""
    legacy_ctx=$(echo "$rs" | jq -r '[.rules[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null || echo "")
    local c
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      if ! grep -qxF "$c" <<< "$sanctioned_ctx"; then
        uncovered+="\`$c\` "
      fi
    done <<< "$legacy_ctx"

    local migrate_note
    if [ -n "$uncovered" ]; then
      migrate_note="**Migrate before deleting** — these required checks are not yet required by \`pr-quality\` or \`code-quality\`, so deleting this ruleset would drop them as merge gates: ${uncovered}Add them to \`code-quality\` first, then delete this ruleset."
    else
      migrate_note="Every required check it carries is already required by a sanctioned ruleset, so it is **safe to delete** (e.g. \`gh api -X DELETE repos/$ORG/$repo/rulesets/$rs_id\`)."
    fi

    add_finding "$repo" "rulesets" "legacy-ruleset-$slug" "error" \
      "Legacy ruleset \`$rs_name\` (id $rs_id) targets the default branch. Only \`pr-quality\` and \`code-quality\` are sanctioned; classic \`protect-branches\` / ad-hoc \`main\` rulesets are deprecated and must be migrated into the two sanctioned rulesets and removed (a duplicate ruleset is a second place every bypass actor must be kept in sync). $migrate_note" \
      "$std_ref"
  done
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
    local content decoded
    content=$(gh_api "repos/$ORG/$repo/contents/$path" --jq '.content' 2>/dev/null || echo "")
    [ -n "$content" ] || continue
    # The contents API always returns the file body as base64. On a 404,
    # `gh api` prints the error body (e.g. `{"message":"Not Found",...}`) to
    # stdout, which is NOT base64 — so if decoding fails, skip this path
    # rather than treating the error JSON as owner lines. The old
    # `base64 -d || echo "$content"` fallback leaked that error body in as a
    # fake owner line, producing bogus codeowners-org-leads-not-first findings.
    decoded=$(printf '%s' "$content" | base64 -d 2>/dev/null) || continue
    [ -n "$decoded" ] || continue
    found=true
    codeowners_content="$decoded"
    break
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
  owner_lines=$(echo "$codeowners_content" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')

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
# Check: SonarCloud S7637 first-party reusable-ref exemption (#498)
#
# SonarCloud's githubactions:S7637 ("pin actions to a full-length commit SHA")
# fires on first-party combsmith/.github(-private) reusable-ref caller
# stubs that the org standard intentionally pins by moving channel/tag rather
# than SHA (see check_action_pinning's exemption and the Action Pinning Policy).
# The two policies are otherwise mutually exclusive on a single pin, so each
# SonarCloud-gated repo must carry a NARROW sonar.issue.ignore that suppresses
# S7637 only on the thin caller-stub workflow files — never a blanket
# workflows/*.yml exclusion, which would also drop SHA-pin enforcement on the
# third-party actions in ci.yml/sonarcloud.yml.
#
# classify_sonar_s7637_exemption echoes exactly one verdict for a given
# sonar-project.properties body:
#   present   — at least one issue-ignore criterion suppresses
#               githubactions:S7637 and every such criterion targets specific
#               caller-stub files (no blanket workflow glob).
#   too-broad — an S7637 criterion uses a blanket resourceKey (the filename
#               segment carries a wildcard, e.g. workflows/*.yml or *.yml, or
#               the pattern is a bare **). This also exempts third-party actions
#               and violates the org policy.
#   missing   — no criterion suppresses githubactions:S7637.
# ---------------------------------------------------------------------------
classify_sonar_s7637_exemption() {
  local content="$1"

  # Criterion keys whose ruleKey assigns githubactions:S7637 (whitespace around
  # the key/`=`/value is tolerated; properties keys are [A-Za-z0-9_]).
  local keys
  keys=$(printf '%s\n' "$content" \
    | grep -E '^[[:space:]]*sonar\.issue\.ignore\.multicriteria\.[A-Za-z0-9_]+\.ruleKey[[:space:]]*=[[:space:]]*githubactions:S7637[[:space:]]*$' \
    | sed -E 's/^[[:space:]]*sonar\.issue\.ignore\.multicriteria\.([A-Za-z0-9_]+)\.ruleKey.*/\1/' || true)

  if [ -z "$keys" ]; then
    echo "missing"
    return
  fi

  local key resourcekey base broad=0
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    resourcekey=$(printf '%s\n' "$content" \
      | grep -E "^[[:space:]]*sonar\\.issue\\.ignore\\.multicriteria\\.${key}\\.resourceKey[[:space:]]*=" \
      | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' | head -n1 || true)
    # A criterion is blanket (too broad) when the filename segment carries a
    # wildcard — e.g. **/.github/workflows/*.yml, *.yml — or the whole pattern
    # is a bare **. Such a pattern also matches ci.yml and would drop S7637 on
    # the third-party actions there.
    base="${resourcekey##*/}"
    if [ "$resourcekey" = "**" ] || case "$base" in *'*'* | *'?'*) true ;; *) false ;; esac; then
      broad=1
    fi
  done <<< "$keys"

  if [ "$broad" -eq 1 ]; then
    echo "too-broad"
  else
    echo "present"
  fi
}

check_sonar_s7637_exemption() {
  local repo="$1"

  # Only relevant when the repo actually runs SonarCloud analysis.
  gh_api "repos/$ORG/$repo/contents/.github/workflows/sonarcloud.yml" --jq '.name' > /dev/null 2>&1 || return

  local content decoded
  content=$(gh_api "repos/$ORG/$repo/contents/sonar-project.properties" --jq '.content' 2>/dev/null || echo "")
  # A missing properties file is reported separately by check_sonarcloud.
  [ -z "$content" ] && return
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return

  local verdict
  verdict=$(classify_sonar_s7637_exemption "$decoded")

  case "$verdict" in
    missing)
      add_finding "$repo" "ci-workflows" "sonar-s7637-exemption-missing" "warning" \
        "\`sonar-project.properties\` has no \`sonar.issue.ignore\` for \`githubactions:S7637\`. SonarCloud will flag first-party reusable-ref caller stubs (\`@<name>/stable\`, \`@v1\`/\`@v2\`) as unpinned actions even though the org exempts them from SHA-pinning. Add the canonical per-stub exemption." \
        "standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637"
      ;;
    too-broad)
      add_finding "$repo" "ci-workflows" "sonar-s7637-exemption-too-broad" "error" \
        "\`sonar-project.properties\` suppresses \`githubactions:S7637\` with a blanket workflow-path \`resourceKey\` (e.g. \`workflows/*.yml\` or \`**\`). This also exempts third-party actions in \`ci.yml\`/\`sonarcloud.yml\` from SHA-pin enforcement. Scope the exemption to the individual caller-stub files instead." \
        "standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637"
      ;;
  esac
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

  # Query the default-setup state.
  # IMPORTANT: Do NOT use the gh_api() retry wrapper here. When gh api gets a
  # 403 it outputs the error JSON body to stdout before exiting non-zero. The
  # retry wrapper loops 3 times without suppressing stdout, so the captured
  # output ends up as 3 concatenated error bodies — indistinguishable from a
  # real "not-configured" state and causing persistent false-positive findings.
  # We capture the response body and exit code separately so we can detect a
  # 403 permission error and skip without filing a spurious finding.
  local raw_response=""
  local api_ok=0
  raw_response=$(gh api "repos/$ORG/$repo/code-scanning/default-setup" 2>/dev/null) || api_ok=$?

  if [ "$api_ok" -ne 0 ]; then
    # Distinguish a 403 permission error from other failures (404, 500, …).
    # The gh api error body contains `"status": "403"` (a JSON string) for
    # "Resource not accessible by personal access token" responses.
    if echo "$raw_response" | jq -e '.status == "403"' > /dev/null 2>&1; then
      # ORG_SCORECARD_TOKEN lacks the security_events scope required by this
      # endpoint. We cannot determine the CodeQL default-setup state, so we
      # skip without adding a finding — a 403 from the audit token must not be
      # misreported as "not configured". To verify state manually run:
      #   gh api repos/$ORG/$repo/code-scanning/default-setup
      # with a token that carries security_events (or repo-admin) scope.
      info "  CodeQL default setup check skipped for $repo — audit token lacks required permissions (403)"
    else
      add_finding "$repo" "ci-workflows" "codeql-default-setup-not-configured" "error" \
        "CodeQL default setup query returned no state — either the repo has code scanning disabled or the API call failed. Enable via \`gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default\`." \
        "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
    fi
  else
    local state
    state=$(echo "$raw_response" | jq -r '.state // ""')
    if [ "$state" != "configured" ]; then
      add_finding "$repo" "ci-workflows" "codeql-default-setup-not-configured" "error" \
        "CodeQL default setup is in state \`$state\` (expected \`configured\`). Run \`apply-repo-settings.sh $repo\` or \`gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default\`." \
        "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
    fi
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
# ---------------------------------------------------------------------------
# Check: ci.yml uses SHA-scoped concurrency group
#
# Per-ref concurrency groups (`ci-${{ github.ref }}`) with cancel-in-progress
# can leave the HEAD commit without CI results when a rapid push arrives while
# the previous cancellation is in flight. The standard requires the group to
# include github.sha so every commit gets its own slot.
#
# See standards/ci-standards.md#1-ci-pipeline-ciyml for the rationale.
# ---------------------------------------------------------------------------
check_ci_concurrency() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/ci.yml" --jq '.content' 2>/dev/null || echo "")
  [ -z "$content" ] && return  # missing ci.yml is caught by check_required_workflows

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return

  # Only flag workflows that have a concurrency block but are missing github.sha.
  # Workflows with no concurrency block at all are not flagged here (they may be
  # intentionally unbounded for reasons outside this check's scope).
  if echo "$decoded" | grep -qE '^concurrency:'; then
    if ! echo "$decoded" | grep -qE 'group:.*github\.sha'; then
      add_finding "$repo" "ci-workflows" "ci-concurrency-missing-sha" "warning" \
        "The \`ci.yml\` concurrency group does not include \`github.sha\`. A per-ref group with \`cancel-in-progress: true\` can leave the HEAD commit with no CI results when pushes arrive in quick succession. Update to: \`group: ci-\${{ github.ref }}-\${{ github.sha }}\`." \
        "standards/ci-standards.md#1-ci-pipeline-ciyml"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: Tier 1 centralized workflows must be thin caller stubs pinned to the
# canonical version tag for their reusable.
#
# For each workflow that the org has centralized into a reusable workflow,
# verify the downstream repo's copy is a stub that delegates via:
#   uses: combsmith/.github/.github/workflows/<reusable>.yml@<version>
#
# This prevents drift: a repo that copies the inline pre-centralization
# version (or pins to @main, or pins to a non-canonical tag) is flagged so
# it can be re-synced from the standard. The central .github repo itself is
# exempt because it owns the reusables and may legitimately reference
# its own workflows by @main during release prep.
#
# Array format: "workflow-filename:reusable-basename:canonical-pin:legacy-csv"
# ---------------------------------------------------------------------------

# stub_pin_acceptable <decoded> <reusable-basename> <canonical-ref> <legacy-csv>
# True if a non-comment `uses:` line pins combsmith/.github's <reusable> at
# the canonical ref OR one of the comma-separated transitional legacy refs. The
# legacy grace keeps a stub on its old @vN pin compliant while the fleet migrates
# to the <name>/stable channel, so the audit neither flags nor reverts it
# mid-migration (#482). Anchored to start-of-line so a `# uses: …` comment never
# counts.
stub_pin_acceptable() {
  local decoded="$1" reusable="$2" canonical="$3" legacy_csv="$4"
  local esc_reusable; esc_reusable=$(escape_ere "$reusable")

  local -a legacy_arr=()
  [ -n "$legacy_csv" ] && IFS=',' read -r -a legacy_arr <<< "$legacy_csv"

  local alt="" r
  for r in "$canonical" "${legacy_arr[@]}"; do
    [ -z "$r" ] && continue
    alt+="${alt:+|}$(escape_ere "$r")"
  done

  local expected="combsmith/\\.github/\\.github/workflows/${esc_reusable}\\.yml@(${alt})"
  printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*${expected}([[:space:]]|$)"
}

# ring_tier_for_repo(), ring_canonical_ref() and ring_legacy_csv() are provided by
# lib/ring-pins.sh (sourced above) — the single source of truth shared with the
# deploy sweep so the audit and the deploy never disagree on a stub's pin (#482).

check_centralized_workflow_stubs() {
  local repo="$1"

  # The .github repo is the source of truth and is allowed to reference its
  # own reusables by @main; skip the stub check for it.
  [ "$repo" = ".github" ] && return

  # workflow-filename:reusable-basename:canonical-pin:legacy-accepted-csv
  #   canonical-pin       — the org-standard ref a stub should pin. The sentinel
  #                         `RING` means "this reusable is on the canary-ring
  #                         model": the expected channel is the repo's RING TIER
  #                         (next/ring0/ring1/stable — see ring_tier_for_repo),
  #                         e.g. `agent-shield/ring1` on a ring1 repo. Any other
  #                         value is a fixed pin (e.g. feature-ideation → v1).
  #   legacy-accepted-csv — additional refs still accepted *during* migration so
  #                         the audit neither flags nor reverts a stub mid-move.
  #                         For RING reusables the per-repo legacy set (the
  #                         `<name>/stable` channel + v1,v2) is computed below.
  # NOTE: dev-lead.yml is intentionally NOT listed here — its reusable lives in
  # the private combsmith/.github-private repo and is pinned to the
  # dev-lead/stable channel, validated by check_dev_lead_stub() below.
  local centralized=(
    "auto-rebase.yml:auto-rebase-reusable:RING"
    "dependency-audit.yml:dependency-audit-reusable:RING"
    "dependabot-automerge.yml:dependabot-automerge-reusable:RING"
    "dependabot-rebase.yml:dependabot-rebase-reusable:RING"
    "agent-shield.yml:agent-shield-reusable:RING"
    "feature-ideation.yml:feature-ideation-reusable:v1:"
    "pr-review-mention.yml:pr-review-mention-reusable:RING"
  )

  # List the repo's workflow directory once instead of probing each file.
  # If the listing fails (no workflows dir), there's nothing to check.
  local workflow_list
  workflow_list=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")
  [ -z "$workflow_list" ] && return

  local entry wf reusable canonical legacy
  for entry in "${centralized[@]}"; do
    IFS=':' read -r wf reusable canonical legacy <<< "$entry"
    [ -z "$canonical" ] && { echo "::error::centralized entry '$entry' missing canonical pin — expected format 'wf:reusable:canonical:legacy-csv'" >&2; exit 1; }

    # RING sentinel: this reusable is on the canary-ring model. The canonical
    # ref is the channel for THIS repo's ring tier (next/ring0/ring1/stable),
    # and the per-repo legacy grace accepts the `<name>/stable` channel plus the
    # pre-ring @v1/@v2 pins so the audit neither flags nor reverts a stub while
    # the fleet migrates onto the rings (#870, same revert-collision lesson as
    # #482). Higher tiers are also acceptable so a repo pinned ahead of its tier
    # (e.g. a ring1 repo still on /stable, or .github-private's /next promoted to
    # /stable) is never flagged — only @main / inline / off-channel pins are.
    if [ "$canonical" = "RING" ]; then
      local chan
      chan="${reusable%-reusable}"
      canonical="$(ring_canonical_ref "$chan" "$repo")"
      legacy="$(ring_legacy_csv "$chan" "$repo")"
    fi

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

    # Compliant if a non-comment `uses:` line pins the reusable at the canonical
    # channel or — transitionally, during the #482 migration — an accepted legacy
    # @vN ref. stub_pin_acceptable anchors to start-of-line so a `# uses: …`
    # comment never satisfies the check.
    if stub_pin_acceptable "$decoded" "$reusable" "$canonical" "$legacy"; then
      continue
    fi

    # Determine why it's non-compliant for a more actionable message.
    local esc_reusable why
    esc_reusable=$(escape_ere "$reusable")
    if echo "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*combsmith/\\.github/\\.github/workflows/${esc_reusable}\\.yml@"; then
      why="references the reusable but is not pinned to \`@${canonical}\` (org standard)"
    elif echo "$decoded" | grep -qF "combsmith/.github/.github/workflows/${reusable}"; then
      why="references the reusable but the \`uses:\` line does not match the canonical stub"
    else
      why="is an inline copy instead of a thin caller stub — re-sync from \`standards/workflows/${wf}\`"
    fi

    add_finding "$repo" "ci-workflows" "non-stub-$wf" "error" \
      "Centralized workflow \`$wf\` $why. Replace with the canonical stub from \`standards/workflows/${wf}\` which delegates to \`combsmith/.github/.github/workflows/${reusable}.yml@${canonical}\`." \
      "standards/ci-standards.md#centralization-tiers"
  done
}

# ---------------------------------------------------------------------------
# Check: dev-lead.yml caller stub conforms to the centralized contract
#
# Unlike the other reusables, dev-lead lives in the PRIVATE repo and is pinned
# to the moving `dev-lead/stable` channel tag (not @main, not a frozen @vN — see
# standards/ci-standards.md#dev-lead-agent for the self-host channel model), and
# its concurrency + permissions are owned centrally. A stub drifts — and breaks —
# in three ways this check catches (all root causes of combsmith/.github#402):
#
#   1. Wrong pin: not combsmith/.github-private/.../dev-lead-reusable.yml@dev-lead/stable.
#   2. Local concurrency block: per-stub concurrency drifts and cancels issue
#      pickups; concurrency is owned by the reusable (per-issue/per-PR lanes).
#   3. Missing `statuses: read`: the reusable requests it since #435, so without
#      it every run fails at startup (startup_failure) with no runtime error.
# ---------------------------------------------------------------------------
check_dev_lead_stub() {
  local repo="$1"

  # .github holds the template (exercised by the reusable's own CI) and
  # .github-private runs the workflow inline rather than as a caller stub.
  [ "$repo" = ".github" ] && return
  [ "$repo" = ".github-private" ] && return

  local content decoded
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/dev-lead.yml" --jq '.content' 2>/dev/null || echo "")
  [ -z "$content" ] && return  # repo hasn't adopted dev-lead — nothing to check
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return

  # 1) Canonical pin (non-comment `uses:` line) — a moving dev-lead channel tag
  #    (self-host channel model). The production default is `stable`; the staged
  #    canary model (versioning.md Phase 2, #499/#500) also permits the candidate
  #    channel `next` and per-ring channels `ring0`, `ring1`, … A frozen `@vX.Y.Z`
  #    or `@<sha>` is NOT a channel and is intentionally rejected — callers pin the
  #    moving channel so rollout/rollback is a single central tag move.
  if ! printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*combsmith/\\.github-private/\\.github/workflows/dev-lead-reusable\\.yml@dev-lead/(stable|next|ring[0-9]+)([[:space:]]|$)"; then
    add_finding "$repo" "ci-workflows" "dev-lead-stub-pin" "error" \
      "The \`dev-lead.yml\` caller stub must pin a \`dev-lead\` channel tag — \`combsmith/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/<channel>\` where <channel> is \`stable\` (default), \`next\`, or \`ring<N>\`. Re-sync from \`standards/workflows/dev-lead.yml\`." \
      "standards/ci-standards.md#dev-lead-agent"
  fi

  # 2) agent_ref must be threaded through to pin the same channel inside the
  #    reusable's own script/prompt checkout (prevents split-brain on promotion).
  #    Same channel set as the uses: pin above; should match the uses: channel.
  uses_channel=$(printf '%s\n' "$decoded" | sed -nE 's#^[[:space:]]*uses:[[:space:]]*combsmith/\.github-private/\.github/workflows/dev-lead-reusable\.yml@dev-lead/(stable|next|ring[0-9]+)([[:space:]]|$).*#\1#p')
  if [ -n "$uses_channel" ]; then
    if ! printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*agent_ref:[[:space:]]*dev-lead/$uses_channel([[:space:]]|$)"; then
      add_finding "$repo" "ci-workflows" "dev-lead-stub-agent-ref" "error" \
        "The \`dev-lead.yml\` caller stub must pass \`with: agent_ref: dev-lead/$uses_channel\` to match the pinned channel \`$uses_channel\`. Re-sync from \`standards/workflows/dev-lead.yml\`." \
        "standards/ci-standards.md#dev-lead-agent"
    fi
  else
    if ! printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*agent_ref:[[:space:]]*dev-lead/(stable|next|ring[0-9]+)([[:space:]]|$)"; then
      add_finding "$repo" "ci-workflows" "dev-lead-stub-agent-ref" "error" \
        "The \`dev-lead.yml\` caller stub must pass \`with: agent_ref: dev-lead/<channel>\` (\`stable\`, \`next\`, or \`ring<N>\`) so the reusable checks out its own scripts/prompts from the same channel. Re-sync from \`standards/workflows/dev-lead.yml\`." \
        "standards/ci-standards.md#dev-lead-agent"
    fi
  fi

  # 3) No per-stub concurrency block — concurrency is owned by the reusable.
  if echo "$decoded" | grep -qE "^concurrency:"; then
    add_finding "$repo" "ci-workflows" "dev-lead-stub-concurrency" "warning" \
      "The \`dev-lead.yml\` stub defines its own \`concurrency:\` block. Concurrency is centralized in the reusable (per-issue/per-PR lanes); a per-stub block drifts and can cancel issue pickups. Remove it — see combsmith/.github#402." \
      "standards/ci-standards.md#dev-lead-agent"
  fi

  # 4) Caller permissions must grant `statuses: read`.
  if ! echo "$decoded" | grep -qE "^[[:space:]]*statuses:[[:space:]]*read([[:space:]]|$)"; then
    add_finding "$repo" "ci-workflows" "dev-lead-stub-statuses-perm" "error" \
      "The \`dev-lead.yml\` stub is missing \`statuses: read\` in \`jobs.dev-lead.permissions\`. The reusable requests it (since #435), so without it every run fails at startup (\`startup_failure\`). Add \`statuses: read\`." \
      "standards/ci-standards.md#dev-lead-agent"
  fi
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
# Check: copilot-setup-steps.yml exists
# ---------------------------------------------------------------------------
# Every repo should have a copilot-setup-steps.yml to pre-install tools and
# dependencies in the Copilot cloud agent environment before it starts work.
# Without it the agent discovers dependencies via trial and error, which is
# slow, non-deterministic, and impossible for repos with private packages.
# See standards/ci-standards.md §11 Copilot Cloud Agent Setup.
# ---------------------------------------------------------------------------
check_copilot_setup_steps() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/copilot-setup-steps.yml" \
    --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-copilot-setup-steps" "warning" \
      "Missing \`.github/workflows/copilot-setup-steps.yml\` — every repo should pre-install tools and dependencies for the Copilot cloud agent. Copy the template from the org standards and uncomment the stack block(s) for this repo." \
      "standards/ci-standards.md"
    return
  fi

  # Verify the workflow contains jobs.copilot-setup-steps specifically.
  # Use a small indentation-based parser (not a loose grep) so comments or similarly
  # named keys elsewhere cannot falsely satisfy this compliance check.
  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  if ! echo "$decoded" | python3 -c '
import re
import sys

lines = sys.stdin.read().splitlines()
jobs_indent = None
child_indent = None
in_jobs = False
found = False

for raw in lines:
    # Skip empty lines and comments
    if re.match(r"^[ \t]*(#.*)?$", raw):
        continue

    indent = len(raw) - len(raw.lstrip(" \t"))
    line = raw.strip()

    if not in_jobs:
        if re.match(r"^jobs:[ \t]*(#.*)?$", line):
            in_jobs = True
            jobs_indent = indent
        continue

    # Left jobs section
    if indent <= jobs_indent:
        break

    # Determine direct-child indentation under jobs (first mapping key)
    if child_indent is None and re.match(r"^[^:#][^:]*:[ \t]*(#.*)?$", line):
        child_indent = indent

    # Match the exact required direct child key (quoted or unquoted YAML key)
    if child_indent is not None and indent == child_indent and re.match(r"^[\"\x27]?copilot-setup-steps[\"\x27]?:[ ]*(#.*)?$", line):
        found = True
        break

sys.exit(0 if found else 1)
'; then
    add_finding "$repo" "standards" "copilot-setup-steps-invalid-job-name" "error" \
      "\`.github/workflows/copilot-setup-steps.yml\` exists but does not contain a job named \`copilot-setup-steps\` — GitHub requires this exact job name to pick up the file." \
      "standards/ci-standards.md"
  fi
}

# ---------------------------------------------------------------------------
# Check: .github/copilot-instructions.md exists with required sections
#
# Every repo SHOULD have a repo-level Copilot instructions file to give
# Copilot specific context it cannot derive from code alone: the active
# tech stack versions, project structure, exact local dev commands, required
# environment variables, and testing thresholds. The org-level baseline in
# combsmith/.github supplies org-wide rules (SOLID, TDD, logging, CI
# gates, PR workflow); repo-level files extend it with repo-specific detail.
# Copilot prioritises repository instructions over org instructions, so the
# repo-level file is the primary surface for per-project customisation.
#
# Checks:
#   1. File present at .github/copilot-instructions.md (warning if missing)
#   2. Required sections present: "## Tech Stack" and "## Local Dev Commands"
#      (warning per missing section)
#
# The .github repo itself is exempt — it holds the canonical template, not
# a per-repo extension.
#
# See standards/copilot-instructions-standard.md for the required sections
# and fill-in template.
# ---------------------------------------------------------------------------
check_copilot_instructions() {
  local repo="$1"

  # The .github repo holds the canonical template — exempt from the
  # per-repo requirement.
  [ "$repo" = ".github" ] && return

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/copilot-instructions.md" \
    --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-copilot-instructions" "error" \
      "Missing \`.github/copilot-instructions.md\`. Every repo must have its own Copilot instructions file — Copilot instruction files are repository-scoped and do not propagate from the \`combsmith/.github\` repo. Copy the canonical template from \`standards/copilot-instructions-standard.md\` in \`combsmith/.github\`, then tailor it with this repo's specific tech stack, project structure, local dev commands, required environment variables, and testing configuration." \
      "standards/copilot-instructions-standard.md"
    return
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  # Strip fenced code blocks before checking for required section headers so
  # that ## headings inside code examples (e.g. template snippets) cannot
  # falsely satisfy the check.
  local prose
  prose=$(echo "$decoded" | awk '/^```/{in_block=!in_block; next} !in_block{print}')

  # Verify required section headers (level-2, case-insensitive)
  local required_sections=("Tech Stack" "Local Dev Commands")
  for section in "${required_sections[@]}"; do
    local slug
    slug=$(echo "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if ! echo "$prose" | grep -qiE "^##[[:space:]]+${section}"; then
      add_finding "$repo" "standards" "copilot-instructions-missing-${slug}" "warning" \
        "\`.github/copilot-instructions.md\` is missing the required \`## $section\` section. See \`standards/copilot-instructions-standard.md\` for the required template and guidance on what to include." \
        "standards/copilot-instructions-standard.md"
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: check-suite auto-trigger disabled for Claude and CodeRabbit
# ---------------------------------------------------------------------------
check_check_suite_prefs() {
  local repo="$1"

  # The GET endpoint returns 404 when check-suite preferences have never been
  # set for this repo — i.e. no app (Claude/CodeRabbit) has created a check run
  # yet, so no orphaned "queued" suite can exist. That is the compliant
  # "missing" state (mirrors the per-app handling below), not a read failure, so
  # it must not raise a finding. Only a genuine unreadable error (auth/scope/
  # network) warrants the warning. apply-repo-settings.sh and
  # fix-check-suite-prefs.sh tolerate this same 404. Capture the GET's combined
  # output and exit status (gh_api swallows both) so the cases can be told apart.
  local prefs="" rc=1 i
  for i in 1 2 3; do
    prefs=$(gh api "repos/$ORG/$repo/check-suites/preferences" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      break
    fi
    # 404 is deterministic and benign — stop retrying and report nothing.
    if grep -q 'HTTP 404' <<< "$prefs"; then
      return 0
    fi
    if [ "$i" -lt 3 ]; then
      sleep $((i * 2))
    fi
  done

  if [ "$rc" -ne 0 ]; then
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
  gh label create "dev-lead" \
    --repo "$ORG/$repo" \
    --description "For dev-lead agent pickup" \
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
    # Update existing issue with a comment; only count as existing if the update succeeds
    local update_ok=true
    gh issue comment "$existing" --repo "$ORG/$repo" \
      --body "**Weekly Compliance Audit** ($(date -u +%Y-%m-%d))

This finding is still open.

**Detail:** $detail

**Standard:** [$standard_ref](https://github.com/$ORG/.github/blob/main/$standard_ref)" 2>/dev/null || update_ok=false
    if [ "$update_ok" = "true" ]; then
      info "Updated existing issue #$existing in $repo for: $check"
      ISSUES_EXISTING=$((ISSUES_EXISTING + 1))
    else
      warn "Failed to update existing issue #$existing in $repo for: $check"
    fi

    # Re-engage dev-lead on findings that PERSIST across audits.
    #
    # dev-lead listens on issues:labeled and fires only once per label
    # application. The `dev-lead` label is already present on a pre-existing
    # issue, so a plain --add-label is a no-op that emits no event and dev-lead
    # is never re-triggered. To give it a fresh chance to produce a fix PR we
    # cycle the label (remove + re-add) — UNLESS dev-lead is already working
    # this issue (open dev-lead PR or `in-progress` label), in which case we
    # leave it alone (the label is already present, so no action is needed).
    if dl_dev_lead_active "$ORG" "$repo" "$existing"; then
      info "Existing issue #$existing in $repo — dev-lead already active, not re-triggering"
    elif dl_cycle_trigger_label "$ORG" "$repo" "$existing" "dev-lead" "$DRY_RUN"; then
      info "Re-triggered dev-lead on persistent issue #$existing in $repo for: $check"
      ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
    else
      # Cycle failed mid-way — ensure the label is at least present so the issue
      # is not left without its trigger label.
      gh issue edit "$existing" --repo "$ORG/$repo" --add-label "dev-lead" 2>/dev/null || true
      warn "Failed to re-trigger dev-lead on issue #$existing in $repo for: $check"
    fi
    # Record existing issue for umbrella
    jq --null-input \
      --arg repo "$repo" \
      --arg category "$category" \
      --arg check "$check" \
      --arg severity "$severity" \
      --arg number "$existing" \
      --arg url "https://github.com/$ORG/$repo/issues/$existing" \
      '{repo:$repo,category:$category,check:$check,severity:$severity,number:$number,url:$url}' \
      >> "$ISSUES_FILE"
    return
  fi

  # Category-specific remediation instructions
  local remediation_steps
  case "$category" in
    settings)
      remediation_steps="Run \`scripts/apply-repo-settings.sh ${repo}\` with a token that has admin access to the repository (requires a classic PAT with \`repo\` scope or equivalent):

\`\`\`bash
GH_TOKEN=<admin-pat> bash scripts/apply-repo-settings.sh ${repo}
\`\`\`

This script applies all standard settings defined in \`standards/github-settings.md\` in one pass.
For a dry run to preview changes without applying: \`DRY_RUN=true GH_TOKEN=<admin-pat> bash scripts/apply-repo-settings.sh ${repo}\`"
      ;;
    ci-workflows|workflows)
      remediation_steps="Copy the relevant workflow template from \`standards/workflows/\` verbatim — do not generate from scratch:

\`\`\`bash
gh api repos/${ORG}/.github/contents/standards/workflows/<template>.yml --jq '.content' | base64 -d > .github/workflows/<template>.yml
\`\`\`

Available templates: \`agent-shield.yml\`, \`dev-lead.yml\`, \`dependabot-automerge.yml\`, \`dependabot-rebase.yml\`, \`dependency-audit.yml\`, \`feature-ideation.yml\`"
      ;;
    labels)
      remediation_steps="Run \`scripts/apply-repo-settings.sh ${repo}\` — it applies standard labels alongside settings:

\`\`\`bash
GH_TOKEN=<admin-pat> bash scripts/apply-repo-settings.sh ${repo}
\`\`\`"
      ;;
    *)
      remediation_steps="Please review the linked standard and bring this repository into compliance.

See the [full standards documentation](https://github.com/${ORG}/.github/tree/main/standards) for implementation guidance."
      ;;
  esac

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

${remediation_steps}

---
*This issue was automatically created by the [weekly compliance audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/compliance-audit.yml).*"

  local issue_url
  # Individual finding issues get both compliance-audit and dev-lead labels so agents can pick them up.
  issue_url=$(gh issue create --repo "$ORG/$repo" \
    --title "$search_title" \
    --label "$AUDIT_LABEL" \
    --label "dev-lead" \
    --body "$body" 2>/dev/null || echo "")

  if [ -n "$issue_url" ]; then
    local new_issue
    new_issue=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
    info "Created issue #$new_issue in $repo for: $check ($issue_url)"
    ISSUES_ADDED=$((ISSUES_ADDED + 1))

    # Record created issue for umbrella
    if [ -n "$new_issue" ]; then
      jq --null-input \
        --arg repo "$repo" \
        --arg category "$category" \
        --arg check "$check" \
        --arg severity "$severity" \
        --arg number "$new_issue" \
        --arg url "$issue_url" \
        '{repo:$repo,category:$category,check:$check,severity:$severity,number:$number,url:$url}' \
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
    "standards|Agent Standards (CLAUDE.md / AGENTS.md / copilot-setup-steps.yml)|per-repo doc and workflow additions"
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
    --label "dev-lead" \
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
      if gh issue close "$issue_num" --repo "$ORG/$repo" \
          --comment "Resolved! This check is now passing as of $(date -u +%Y-%m-%d). Closing automatically." \
          2>/dev/null; then
        info "Closed resolved issue #$issue_num in $repo: $issue_title"
        ISSUES_REMOVED=$((ISSUES_REMOVED + 1))
      else
        warn "Failed to close resolved issue #$issue_num in $repo: $issue_title"
      fi
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

HEREDOC

  if [ "$total_findings" -eq 0 ]; then
    echo "All repositories are fully compliant! No findings." >> "$SUMMARY_FILE"
    return
  fi

  # ── Findings by Check Type ──────────────────────────────────────────────────
  # Group by check name (not repo) to surface cross-repo patterns at a glance.
  # Errors first, then warnings; within each severity sorted by category then check.
  cat >> "$SUMMARY_FILE" <<'HEREDOC'
## Findings by Check Type

| Check | Severity | Category | Repos Affected |
|-------|----------|----------|----------------|
HEREDOC

  jq -r --arg org "$ORG" '
    group_by(.check)
    | map({
        check:      .[0].check,
        category:   .[0].category,
        severity:   .[0].severity,
        repos:      [.[].repo]
      })
    | sort_by([(if .severity == "error" then 0 else 1 end), .category, .check])
    | .[]
    | "| `\(.check)` | `\(.severity)` | \(.category) | \(.repos | map("[`" + . + "`](https://github.com/" + $org + "/" + . + ")") | join(", ")) |"
  ' "$FINDINGS_FILE" >> "$SUMMARY_FILE"

  # ── Per-Repo Scorecard ───────────────────────────────────────────────────────
  cat >> "$SUMMARY_FILE" <<'HEREDOC'

## Per-Repo Scorecard

| Repo | Errors | Warnings | Total |
|------|--------|----------|-------|
HEREDOC

  jq -r --arg org "$ORG" '
    group_by(.repo)
    | map({
        repo:     .[0].repo,
        errors:   ([.[] | select(.severity == "error")]   | length),
        warnings: ([.[] | select(.severity == "warning")] | length),
        total:    length
      })
    | sort_by(-.total)
    | .[]
    | "| [**\(.repo)**](https://github.com/" + $org + "/" + .repo + ") | \(.errors) | \(.warnings) | **\(.total)** |"
  ' "$FINDINGS_FILE" >> "$SUMMARY_FILE"

  # ── Category breakdown ───────────────────────────────────────────────────────
  cat >> "$SUMMARY_FILE" <<'HEREDOC'

## Findings by Category

HEREDOC

  for category in ci-workflows action-pinning dependabot settings push-protection labels rulesets standards; do
    local cat_count
    cat_count=$(jq --arg cat "$category" '[.[] | select(.category == $cat)] | length' "$FINDINGS_FILE")
    if [ "$cat_count" -gt 0 ]; then
      echo "- **$category:** $cat_count finding(s)" >> "$SUMMARY_FILE"
    fi
  done
  # Footer appended by main() after issue links are added
}

# ---------------------------------------------------------------------------
# Issue & PR link summary (appended after issue creation)
# ---------------------------------------------------------------------------
append_issue_pr_links() {
  [ -s "$ISSUES_FILE" ] || return

  # Collect open PRs per affected repo (one GraphQL call per repo) to find
  # those whose closingIssuesReferences include one of our compliance issues.
  local pr_data_file
  pr_data_file=$(mktemp)
  echo '[]' > "$pr_data_file"

  local repos_in_issues
  repos_in_issues=$(jq -rn '[inputs | .repo] | unique[]' "$ISSUES_FILE" 2>/dev/null || echo "")

  for repo in $repos_in_issues; do
    local repo_prs
    repo_prs=$(gh api graphql \
      -f owner="$ORG" -f name="$repo" \
      -f query='query($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){
          pullRequests(states:OPEN,first:100){
            nodes{
              number url
              closingIssuesReferences(first:10){nodes{number}}
            }
          }
        }
      }' 2>/dev/null \
      | jq --arg repo "$repo" '[
          .data.repository.pullRequests.nodes[] | {
            repo:      $repo,
            pr_number: .number,
            pr_url:    .url,
            closes:    [.closingIssuesReferences.nodes[].number]
          }
        ]' 2>/dev/null || echo '[]')

    jq -n \
      --argjson existing "$(cat "$pr_data_file")" \
      --argjson new_prs "$repo_prs" \
      '$existing + $new_prs' > "$pr_data_file.tmp" \
      && mv "$pr_data_file.tmp" "$pr_data_file"
  done

  cat >> "$SUMMARY_FILE" <<'HEREDOC'

## Issues & Related PRs

Grouped by compliance check type. Each entry links to the GitHub Issue for the
finding in each affected repo; **Related PRs** shows open pull requests that
close that issue.

HEREDOC

  # Iterate checks in severity then alphabetical order
  local checks_ordered
  checks_ordered=$(jq -rn '[inputs]
    | group_by(.check)
    | map({check: .[0].check, severity: .[0].severity})
    | sort_by([(if .severity == "error" then 0 else 1 end), .check])
    | .[].check
  ' "$ISSUES_FILE" 2>/dev/null || echo "")

  while IFS= read -r check; do
    [ -z "$check" ] && continue

    local check_issues severity category issue_count
    check_issues=$(jq -cn --arg c "$check" '[inputs | select(.check == $c)] | sort_by(.repo)' "$ISSUES_FILE")
    severity=$(jq -r '.[0].severity' <<< "$check_issues")
    category=$(jq -r '.[0].category' <<< "$check_issues")
    issue_count=$(jq 'length' <<< "$check_issues")

    printf '\n### `%s`\n' "$check" >> "$SUMMARY_FILE"
    printf '**Severity:** `%s` | **Category:** %s | **%d repo(s) affected**\n\n' \
      "$severity" "$category" "$issue_count" >> "$SUMMARY_FILE"
    printf '| Repo | Issue | Related PRs |\n' >> "$SUMMARY_FILE"
    printf '|------|-------|-------------|\n' >> "$SUMMARY_FILE"

    while IFS= read -r issue_entry; do
      local repo issue_num issue_url pr_links
      repo=$(jq -r '.repo'    <<< "$issue_entry")
      issue_num=$(jq -r '.number' <<< "$issue_entry")
      issue_url=$(jq -r '.url'    <<< "$issue_entry")

      pr_links=$(jq -r \
        --arg repo "$repo" \
        --argjson inum "$issue_num" \
        '[.[] | select(.repo == $repo and (.closes | map(. == $inum) | any))
          | "[#\(.pr_number)](\(.pr_url))"]
        | if length > 0 then join(", ") else "—" end' \
        "$pr_data_file")

      printf '| [%s](https://github.com/%s/%s) | [#%s](%s) | %s |\n' \
        "$repo" "$ORG" "$repo" "$issue_num" "$issue_url" "$pr_links" \
        >> "$SUMMARY_FILE"
    done < <(jq -c '.[]' <<< "$check_issues")
  done <<< "$checks_ordered"

  rm -f "$pr_data_file"
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
      "Check that ORG_SCORECARD_TOKEN is valid. If using a Fine-Grained token, ensure it has repository permissions: 'Administration: Read-only', 'Metadata: Read-only', 'Contents: Read-only', 'Issues: Read and write'; and organization permission: 'Metadata: Read-only' (required to list repositories)." >&2
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
    check_rulesets "$repo" "$repo_json"
    check_codeowners "$repo"
    check_sonarcloud "$repo"
    check_sonar_s7637_exemption "$repo"
    check_codeql_default_setup "$repo"
    check_workflow_permissions "$repo"
    check_ci_concurrency "$repo"
    check_centralized_workflow_stubs "$repo"
    check_dev_lead_stub "$repo"
    check_centralized_check_names "$repo"
    check_claude_md "$repo"
    check_agents_md "$repo"
    check_copilot_setup_steps "$repo"
    check_copilot_instructions "$repo"
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
    # Both individual issues and the umbrella get the `dev-lead` label for agent pickup.
    create_umbrella_issue

    # Append per-check issue links and related open PRs to the step summary
    info "Fetching linked PRs for issue summary..."
    append_issue_pr_links
  else
    info "Skipping issue creation (DRY_RUN=$DRY_RUN, CREATE_ISSUES=$CREATE_ISSUES)"
  fi

  # Write issue-management counts and append to summary (conditional on issue management running)
  if [ "$CREATE_ISSUES" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    printf '{"added":%d,"existing":%d,"removed":%d,"retriggered":%d}\n' \
      "$ISSUES_ADDED" "$ISSUES_EXISTING" "$ISSUES_REMOVED" "$ISSUES_RETRIGGERED" > "$ISSUE_COUNTS_FILE"
    cat >> "$SUMMARY_FILE" <<HEREDOC

## Issue Management

| Action | Count |
|--------|-------|
| Added (new) | $ISSUES_ADDED |
| Existing (updated) | $ISSUES_EXISTING |
| Re-triggered (dev-lead re-engaged) | $ISSUES_RETRIGGERED |
| Removed (resolved) | $ISSUES_REMOVED |
HEREDOC
  else
    printf '{"added":0,"existing":0,"removed":0,"retriggered":0}\n' > "$ISSUE_COUNTS_FILE"
    cat >> "$SUMMARY_FILE" <<HEREDOC

## Issue Management

_Issue management was skipped (DRY\_RUN=$DRY_RUN, CREATE\_ISSUES=$CREATE_ISSUES)._
HEREDOC
  fi

  # Append footer (always last)
  cat >> "$SUMMARY_FILE" <<HEREDOC

---
*Generated by the [weekly compliance audit](https://github.com/$ORG/.github/blob/main/.github/workflows/compliance-audit.yml) on $(date -u "+%Y-%m-%d %H:%M UTC").*
HEREDOC

  # Output report paths
  echo "findings=$FINDINGS_FILE"
  echo "summary=$SUMMARY_FILE"

  info "Summary written to $SUMMARY_FILE"
  info "Findings written to $FINDINGS_FILE"

  cat "$SUMMARY_FILE"
}

# Run main only when executed directly, not when sourced (e.g. by bats tests
# that exercise individual helper functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
