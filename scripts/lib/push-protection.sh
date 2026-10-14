# shellcheck shell=bash
# scripts/lib/push-protection.sh — Shared push-protection logic
#
# Sourceable Bash library that implements the apply + check functions for
# the combsmith Push Protection Standard:
#
#   standards/push-protection.md
#
# Both scripts/apply-repo-settings.sh and scripts/compliance-audit.sh source
# this file so the org-required `security_and_analysis` settings, audit
# checks, and remediation logic live in exactly one place. Any future change
# to the standard's required state happens here, not in two parallel copies.
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# This library is `set -euo pipefail`-safe and designed to be sourced by a
# parent script. It does NOT call `set` itself.
#
# Required by ALL functions:
#   - $ORG          — GitHub org slug (e.g. "combsmith")
#
# Required by `pp_apply_*` functions (used by apply-repo-settings.sh):
#   - info(), ok(), err(), skip()  — log helpers (string arg)
#   - $DRY_RUN                      — "true" / "false"
#   - `gh` CLI on PATH, GH_TOKEN with admin:repo scope
#
# Required by `pp_check_*` functions (used by compliance-audit.sh):
#   - gh_api()      — wrapper around `gh api` with retry
#   - add_finding() — add_finding <repo> <category> <check> <severity> <detail> [<standard_ref>]
#   - `gh` CLI on PATH, GH_TOKEN with read:org + repo scope
#
# Functions are namespaced with the `pp_` prefix to avoid colliding with
# caller helpers.

# ---------------------------------------------------------------------------
# Required state — single source of truth
# ---------------------------------------------------------------------------
# Each entry: "api_key:expected_value:severity:human_detail"
# Severity is one of: error, warning. The audit and the apply script both
# read from this list, so adding a new flag here automatically extends both.
PP_REQUIRED_SA_SETTINGS=(
  "secret_scanning:enabled:error:Secret scanning must be enabled"
  "secret_scanning_push_protection:enabled:error:Secret scanning push protection must be enabled"
  "secret_scanning_ai_detection:enabled:warning:Secret scanning AI detection should be enabled (requires GitHub Copilot subscription; absent means the feature is unavailable for the current org plan)"
  "secret_scanning_non_provider_patterns:enabled:warning:Secret scanning non-provider patterns should be enabled (requires GitHub Advanced Security)"
  "dependabot_security_updates:enabled:warning:Dependabot security updates should be enabled"
)

# Plan-gated keys that cannot be configured without a plan upgrade. A null/absent
# status for these keys is not actionable and should not generate a finding.
PP_PLAN_GATED_KEYS=(
  "secret_scanning_ai_detection"
  "secret_scanning_non_provider_patterns"
  "dependabot_security_updates"
)

# Keys that specifically require GitHub Advanced Security (GHAS). Unlike the
# plan-gated keys above, when GHAS is unavailable GitHub reports these as
# "disabled" (present, not absent) and silently ignores any PATCH to enable
# them (HTTP 200, no change). A non-compliant status is therefore non-actionable
# whenever security_and_analysis.advanced_security.status is not "enabled", so
# the finding must be suppressed to avoid a recurring, un-fixable audit warning.
PP_GHAS_GATED_KEYS=(
  "secret_scanning_non_provider_patterns"
)

# Minimum entries that every repo's .gitignore MUST contain. Every repo
# starting from the org baseline at /.gitignore satisfies these by default.
PP_REQUIRED_GITIGNORE_PATTERNS=(
  ".env"
  "*.pem"
  "*.key"
)

# Number of days back the bypass-recency check looks for unjustified
# push-protection bypasses.
PP_BYPASS_LOOKBACK_DAYS="${PP_BYPASS_LOOKBACK_DAYS:-30}"

# Standard reference path used by every check finding.
PP_STANDARD_REF="standards/push-protection.md"

# ---------------------------------------------------------------------------
# Apply: security_and_analysis (used by apply-repo-settings.sh)
# ---------------------------------------------------------------------------
# Idempotent: fetches current state, only PATCHes when at least one flag
# differs from the required value. Honors $DRY_RUN.
pp_apply_security_and_analysis() {
  local repo="$1"
  info "Applying push-protection security_and_analysis to $ORG/$repo ..."

  local current
  current=$(gh api "repos/$ORG/$repo" --jq '.security_and_analysis // {}' 2>/dev/null || echo "{}")

  if [ "$current" = "{}" ] || [ -z "$current" ]; then
    # Cannot read the current security_and_analysis state — the token may lack
    # admin or security_events scope, or the settings have not yet been
    # configured.  Apply all required settings unconditionally: every required
    # value is "enabled", so this is idempotent and safe.
    info "  security_and_analysis is currently unreadable — applying all required settings"
  fi

  local needs_patch=false
  local payload="{}"

  local entry key expected actual
  for entry in "${PP_REQUIRED_SA_SETTINGS[@]}"; do
    IFS=':' read -r key expected _ _ <<< "$entry"
    actual=$(echo "$current" | jq -r ".\"$key\".status // \"null\"")

    if [ "$actual" != "$expected" ]; then
      info "  $key: $actual → $expected"
      needs_patch=true
      payload=$(echo "$payload" | jq --arg k "$key" --arg v "$expected" '. + {($k): {status: $v}}')
    else
      ok "  $key: already $actual"
    fi
  done

  if [ "$needs_patch" = false ]; then
    ok "$ORG/$repo security_and_analysis already fully compliant — no changes needed"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    skip "DRY_RUN=true — skipping security_and_analysis PATCH for $ORG/$repo"
    return 0
  fi

  # Wrap the per-key payload in a top-level security_and_analysis object and
  # PATCH it via stdin (gh api -F doesn't accept nested JSON).
  local full_payload
  full_payload=$(echo "$payload" | jq '{security_and_analysis: .}')

  if echo "$full_payload" | gh api -X PATCH "repos/$ORG/$repo" --input - > /dev/null 2>&1; then
    ok "$ORG/$repo security_and_analysis PATCH accepted"

    # Verify each patched key was actually applied. Some settings (e.g.
    # secret_scanning_ai_detection, secret_scanning_non_provider_patterns)
    # require GitHub Advanced Security or a Copilot subscription; the API
    # accepts the PATCH (HTTP 200) but silently ignores keys that the org
    # plan does not support. Re-fetch and warn for any key still not applied.
    local post_patch post_actuals
    post_patch=$(gh api "repos/$ORG/$repo" --jq '.security_and_analysis // {}' 2>/dev/null || echo "{}")
    post_actuals=$(echo "$post_patch" | jq -r 'to_entries | .[] | "\(.key):\(.value.status? // "null")"' 2>/dev/null || echo "")

    local -A actuals
    while IFS=':' read -r k v; do
      if [ -n "$k" ]; then
        actuals["$k"]="$v"
      fi
    done <<< "$post_actuals"

    local post_entry post_key post_expected post_actual
    for post_entry in "${PP_REQUIRED_SA_SETTINGS[@]}"; do
      IFS=':' read -r post_key post_expected _ _ <<< "$post_entry"
      post_actual="${actuals[$post_key]:-null}"
      if [ "$post_actual" != "$post_expected" ]; then
        info "  $post_key still not $post_expected after PATCH — the org plan may not support this feature (current: $post_actual)"
      else
        ok "  $post_key: $post_actual (verified)"
      fi
    done
  else
    err "Failed to PATCH security_and_analysis for $ORG/$repo — the authenticated token must have repository admin permissions (or the org plan may not support these features)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Check: security_and_analysis (used by compliance-audit.sh)
# ---------------------------------------------------------------------------
# Reads the same PP_REQUIRED_SA_SETTINGS list the apply function uses, so
# the audit can never drift from what apply enforces.
pp_check_security_and_analysis() {
  local repo="$1"

  local sa
  sa=$(gh_api "repos/$ORG/$repo" --jq '.security_and_analysis // {}' 2>/dev/null || echo "{}")

  if [ "$sa" = "{}" ] || [ -z "$sa" ]; then
    # security_and_analysis is not readable via the current token (requires
    # admin permissions on the repository).  Use the secret-scanning alerts
    # endpoint as a proxy: an admin with the security_events scope (but not
    # the full repo scope) can access the alerts endpoint even when
    # security_and_analysis is unavailable due to scope differences.  Note:
    # the alerts endpoint requires repository admin privileges regardless of
    # visibility — public repositories do not bypass the admin requirement.
    # A valid array response confirms scanning is active; a non-array
    # response (404/error) suggests it may be disabled.
    local alerts_response
    alerts_response=$(gh_api \
      "repos/$ORG/$repo/secret-scanning/alerts?state=open&per_page=1" \
      2>/dev/null || echo "null")

    if echo "$alerts_response" | jq -e 'type == "array"' > /dev/null 2>&1; then
      # Alerts API returned a valid array — secret scanning is active.
      # Remaining settings (push_protection, ai_detection, non_provider_patterns,
      # dependabot_security_updates) cannot be individually verified without
      # admin / security_events scope; report as partially unverifiable so the
      # finding reflects the actual state of knowledge.
      add_finding "$repo" "push-protection" "security_and_analysis_unverifiable" "warning" \
        "Secret scanning is active but secret_scanning_push_protection, secret_scanning_ai_detection, secret_scanning_non_provider_patterns, and dependabot_security_updates cannot be individually verified — the audit token lacks repository admin permissions. To enable audit verification: regenerate the PAT backing ORG_SCORECARD_TOKEN with the security_events scope (Developer Settings → Personal access tokens) and update the secret value. To enforce all required settings: run \`scripts/apply-repo-settings.sh $repo\` with a repository-admin token." \
        "$PP_STANDARD_REF#required-repo-level-settings"
    else
      # Both the primary API field and the proxy check indicate that scanning
      # may be disabled or the token cannot reach the API at all.
      add_finding "$repo" "push-protection" "security_and_analysis_unavailable" "warning" \
        "Could not fetch security_and_analysis and the secret-scanning alerts proxy check also returned a non-array response — token may lack admin or \`security_events\` OAuth scope, or secret scanning may be disabled. Run \`scripts/apply-repo-settings.sh $repo\` with an admin token to enable all required settings, then add \`security_events\` scope to \`ORG_SCORECARD_TOKEN\` to allow the audit to verify them." \
        "$PP_STANDARD_REF#required-repo-level-settings"
    fi
    return
  fi

  # GitHub Advanced Security availability gates the GHAS-only settings below.
  # When advanced_security is absent or not "enabled", GHAS is unavailable.
  local ghas_status
  ghas_status=$(echo "$sa" | jq -r '.advanced_security.status // "null"')

  local entry key expected severity detail actual is_plan_gated is_ghas_gated
  for entry in "${PP_REQUIRED_SA_SETTINGS[@]}"; do
    IFS=':' read -r key expected severity detail <<< "$entry"
    actual=$(echo "$sa" | jq -r ".\"$key\".status // \"null\"")
    if [ "$actual" = "$expected" ]; then
      continue
    fi
    # A null/absent status for a plan-gated key means the feature is unavailable
    # for the current org plan — skip rather than creating a non-actionable
    # compliance finding that cannot be remediated without a plan upgrade.
    is_plan_gated=false
    for plan_key in "${PP_PLAN_GATED_KEYS[@]}"; do
      if [ "$key" = "$plan_key" ]; then
        is_plan_gated=true
        break
      fi
    done
    if [ "$is_plan_gated" = true ] && [ "$actual" = "null" ]; then
      continue
    fi
    # A GHAS-gated key reported as anything other than "enabled" (including
    # "disabled") is non-actionable when GHAS itself is unavailable — GitHub
    # accepts but silently ignores PATCHes to enable it, so flagging it would
    # produce a recurring finding that can never be remediated on this plan.
    is_ghas_gated=false
    for ghas_key in "${PP_GHAS_GATED_KEYS[@]}"; do
      if [ "$key" = "$ghas_key" ]; then
        is_ghas_gated=true
        break
      fi
    done
    if [ "$is_ghas_gated" = true ] && [ "$ghas_status" != "enabled" ]; then
      continue
    fi
    add_finding "$repo" "push-protection" "$key" "$severity" \
      "$detail (current: \`$actual\`, expected: \`$expected\`)" \
      "$PP_STANDARD_REF#required-repo-level-settings"
  done
}

# ---------------------------------------------------------------------------
# Check: open secret-scanning alerts
# ---------------------------------------------------------------------------
# Any open alert is a real leaked credential that needs rotation. This is an
# `error` finding — open alerts MUST be triaged within the SLA in the
# incident-response section of the standard.
pp_check_open_secret_alerts() {
  local repo="$1"

  local alerts
  alerts=$(gh_api "repos/$ORG/$repo/secret-scanning/alerts?state=open&per_page=100" 2>/dev/null || echo "[]")

  # 404 / disabled secret scanning produces a non-array response; coerce to []
  if ! echo "$alerts" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return
  fi

  local count
  count=$(echo "$alerts" | jq 'length')

  if [ "$count" -gt 0 ]; then
    add_finding "$repo" "push-protection" "open_secret_alerts" "error" \
      "$count open secret-scanning alert(s) — rotate the leaked credentials before resolving" \
      "$PP_STANDARD_REF#incident-response"
  fi
}

# ---------------------------------------------------------------------------
# Check: ci.yml contains a secret-scan job using gitleaks
# ---------------------------------------------------------------------------
pp_check_secret_scan_ci_job() {
  local repo="$1"

  local ci_b64
  ci_b64=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/ci.yml" --jq '.content // ""' 2>/dev/null || echo "")

  if [ -z "$ci_b64" ]; then
    add_finding "$repo" "push-protection" "secret_scan_ci_job_present" "error" \
      "No \`.github/workflows/ci.yml\` found — cannot verify the required \`secret-scan\` gitleaks job" \
      "$PP_STANDARD_REF#layer-3--ci-secret-scanning-secondary-defense"
    return
  fi

  local ci_content
  # GitHub returns content base64-encoded, line-wrapped at 60 chars
  ci_content=$(echo "$ci_b64" | tr -d '\n ' | base64 -d 2>/dev/null || echo "")

  if [ -z "$ci_content" ]; then
    return
  fi

  # Accept either the gitleaks action or the gitleaks CLI (inline or block run:).
  # The action requires a paid org license (gitleaks.io); the CLI installed via
  # binary download is a license-free alternative.
  if ! echo "$ci_content" | grep -qE '(^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*(gitleaks/gitleaks-action|zricethezav/gitleaks-action)@|gitleaks[[:space:]]+detect([[:space:]]|$))'; then
    add_finding "$repo" "push-protection" "secret_scan_ci_job_present" "error" \
      "\`ci.yml\` does not contain a job using \`gitleaks\` — add the secret-scan job from the standard" \
      "$PP_STANDARD_REF#required-ci-job"
  fi
}

# ---------------------------------------------------------------------------
# Check: .gitignore contains the baseline secret-protection entries
# ---------------------------------------------------------------------------
pp_check_gitignore_secrets_block() {
  local repo="$1"

  local gi_b64
  gi_b64=$(gh_api "repos/$ORG/$repo/contents/.gitignore" --jq '.content // ""' 2>/dev/null || echo "")

  if [ -z "$gi_b64" ]; then
    add_finding "$repo" "push-protection" "gitignore_secrets_block" "warning" \
      "No \`.gitignore\` at repo root — start from the org baseline at /.gitignore" \
      "$PP_STANDARD_REF#required-gitignore-entries"
    return
  fi

  local gi_content
  gi_content=$(echo "$gi_b64" | tr -d '\n ' | base64 -d 2>/dev/null || echo "")

  if [ -z "$gi_content" ]; then
    return
  fi

  local missing=()
  local pattern
  for pattern in "${PP_REQUIRED_GITIGNORE_PATTERNS[@]}"; do
    # Use fixed-string match anchored to a line; ignore lines that start with `!`
    # so a negation can't satisfy the requirement for the broad pattern.
    if ! echo "$gi_content" | grep -vE '^[[:space:]]*!' | grep -qxF "$pattern"; then
      missing+=("$pattern")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    add_finding "$repo" "push-protection" "gitignore_secrets_block" "warning" \
      "\`.gitignore\` is missing baseline secret patterns: $(IFS=', '; echo "${missing[*]}") — copy the org baseline at /.gitignore" \
      "$PP_STANDARD_REF#required-gitignore-entries"
  fi
}

# ---------------------------------------------------------------------------
# Check: recent push-protection bypasses
# ---------------------------------------------------------------------------
# Queries the secret-scanning alerts endpoint and looks for any alert that
# was bypassed via push protection within the lookback window. We can't tell
# from the alert payload whether a bypass had a documented justification, so
# this fires as a `warning` and the human reviewer must verify.
pp_check_push_protection_bypasses() {
  local repo="$1"

  local alerts
  alerts=$(gh_api "repos/$ORG/$repo/secret-scanning/alerts?per_page=100" 2>/dev/null || echo "[]")

  if ! echo "$alerts" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return
  fi

  # Cutoff: now - PP_BYPASS_LOOKBACK_DAYS, in ISO-8601
  local cutoff
  if date -u -d "$PP_BYPASS_LOOKBACK_DAYS days ago" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    # GNU date (Linux / GitHub Actions runners)
    cutoff=$(date -u -d "$PP_BYPASS_LOOKBACK_DAYS days ago" "+%Y-%m-%dT%H:%M:%SZ")
  else
    # BSD date (macOS) fallback
    cutoff=$(date -u -v-"${PP_BYPASS_LOOKBACK_DAYS}d" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  fi

  if [ -z "$cutoff" ]; then
    return
  fi

  local recent_bypasses
  recent_bypasses=$(echo "$alerts" | jq --arg cutoff "$cutoff" '
    [.[] | select(
      .push_protection_bypassed == true and
      (.push_protection_bypassed_at != null) and
      (.push_protection_bypassed_at >= $cutoff)
    )] | length
  ' 2>/dev/null || echo "0")

  if [ "$recent_bypasses" -gt 0 ]; then
    add_finding "$repo" "push-protection" "push_protection_bypasses_recent" "warning" \
      "$recent_bypasses push-protection bypass(es) in the last $PP_BYPASS_LOOKBACK_DAYS days — verify each had a documented justification" \
      "$PP_STANDARD_REF#bypass-policy"
  fi
}

# ---------------------------------------------------------------------------
# Convenience: run every push-protection check for one repo
# ---------------------------------------------------------------------------
# Callers may call individual checks if they want to interleave with other
# work, but the audit's per-repo loop just calls this single entry point.
pp_run_all_checks() {
  local repo="$1"
  pp_check_security_and_analysis "$repo"
  pp_check_open_secret_alerts "$repo"
  pp_check_secret_scan_ci_job "$repo"
  pp_check_gitignore_secrets_block "$repo"
  pp_check_push_protection_bypasses "$repo"
}
