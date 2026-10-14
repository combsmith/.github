#!/usr/bin/env bash
# apply-repo-settings.sh — Apply standard repository settings to combsmith repos
#
# Companion script to compliance-audit.sh. Applies the settings defined in:
#   standards/github-settings.md#repository-settings--standard-defaults
#   standards/push-protection.md#required-repo-level-settings
#
# Usage:
#   # Apply to a specific repo:
#   GH_TOKEN=<admin-token> ./scripts/apply-repo-settings.sh <repo-name>
#
#   # Apply to all non-archived org repos:
#   GH_TOKEN=<admin-token> ./scripts/apply-repo-settings.sh --all
#
#   # Dry run (show what would be changed):
#   DRY_RUN=true GH_TOKEN=<admin-token> ./scripts/apply-repo-settings.sh <repo-name>
#
# Requirements:
#   - Bash 4+ (uses associative arrays — macOS ships Bash 3.2; use GitHub Actions or brew install bash)
#   - GH_TOKEN must have admin:repo scope (or be an admin of the org)
#   - gh CLI must be installed

set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] Bash 4+ required (associative arrays). Found: $BASH_VERSION" >&2
  echo "        On macOS: brew install bash, then run with /opt/homebrew/bin/bash" >&2
  exit 1
fi

ORG="combsmith"
DRY_RUN="${DRY_RUN:-false}"

# Source of the persona manifests that the <id>:hands-off opt-out label family is
# derived from. `.github-private` is PUBLIC (private:false, verified) despite its
# name, so these reads work over the token already required by this script and need
# no extra auth. See standards/persona-standards.md §1.1 (the manifest is the
# index-of-record) and §4 rule 4 (every persona defines an opt_out_label).
PERSONA_MANIFEST_REPO="${PERSONA_MANIFEST_REPO:-combsmith/.github-private}"
PERSONA_MANIFEST_REF="${PERSONA_MANIFEST_REF:-main}"

# One consistent color for the entire opt-out family — neutral grey, deliberately
# distinct from the functional labels (security/bug red, dependency/docs blue,
# in-progress yellow). Documented in standards/github-settings.md#labels--standard-set.
PERSONA_OPT_OUT_COLOR="ededed"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*" >&2; }
err()   { echo "[ERROR] $*" >&2; }
skip()  { echo "[SKIP]  $*"; }

# App IDs whose auto_trigger_checks must be disabled — these apps create
# orphaned "queued" suites on every push that are never completed, permanently
# blocking GitHub auto-merge.
# 1236702 = Claude (anthropics/claude-code-action)
# 347564  = CodeRabbit
CHECK_SUITE_APP_IDS=(1236702 347564)

# Source the shared push-protection library — provides
# pp_apply_security_and_analysis() and the PP_REQUIRED_SA_SETTINGS list.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-protection.sh
. "$SCRIPT_DIR/lib/push-protection.sh"

usage() {
  echo "Usage: $0 <repo-name>"
  echo "       $0 --all"
  echo ""
  echo "Environment variables:"
  echo "  GH_TOKEN   GitHub token with admin:repo scope (required)"
  echo "  DRY_RUN    Set to 'true' to preview changes without applying (default: false)"
  exit 1
}

# Populated on the first apply_labels() call; reused for every subsequent repo in
# --all mode. persona_opt_out_label_configs runs in a subshell so the cache must
# live at the apply_labels level, not inside the function.
_PERSONA_OPT_OUT_CONFIGS_CACHE=()
_PERSONA_OPT_OUT_CONFIGS_CACHED=false

# Set when the persona opt-out family could not be derived faithfully — either the
# manifest listing failed, or a manifest could not be read and its label had to be
# guessed from the convention. The run then MUST NOT report success.
#
# Why this exists (combsmith/.github#755): the opt-out family is the escape
# hatch §4 rule 4 mandates. Printing "All repos processed successfully" while it is
# silently absent means nobody learns until someone tells a persona to leave an
# issue alone and it ignores them. Reading an error as a negative answer is the
# systemic bug this framework already had four instances of; this is not the fifth.
_PERSONA_OPT_OUT_SYNC_FAILED=false

# persona_opt_out_label_configs — emit one "name|color|description" line per persona,
# deriving the <id>:hands-off opt-out label from the persona manifests rather than a
# hand-maintained list. Adding a persona therefore needs NO edit here: the family
# follows from personas/<id>/persona.yml, the index-of-record (persona-standards.md
# §1.1). Draft personas are included — being able to say "hands-off" is exactly what
# a draft needs.
#
# Returns non-zero if the family could not be derived faithfully. It still emits
# whatever it resolved (so a hiccup never blocks the STATIC label set — that
# resilience is deliberate), but the caller records the failure and the run exits
# non-zero rather than claiming success. Emitting nothing and returning 0 would
# make "labels applied ✅" indistinguishable from "the opt-out hatch is missing".
persona_opt_out_label_configs() {
  local ids id opt_out opt_out_raw rc=0
  ids=$(gh api "repos/$PERSONA_MANIFEST_REPO/contents/personas?ref=$PERSONA_MANIFEST_REF" 2>/dev/null \
        | jq -r '.[]? | select(.type == "dir") | .name' 2>/dev/null) || {
    warn "  Could not list persona manifests from $PERSONA_MANIFEST_REPO — opt-out labels NOT applied"
    return 1
  }

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # Prefer the manifest's declared opt_out_label; fall back to the <id>:hands-off
    # convention (persona-standards.md §4 rule 4) when the field cannot be read.
    if opt_out_raw=$(gh api "repos/$PERSONA_MANIFEST_REPO/contents/personas/$id/persona.yml?ref=$PERSONA_MANIFEST_REF" \
                       -H "Accept: application/vnd.github.raw" 2>/dev/null); then
      # `opt_out_label` is a free-form string in the schema, and GitHub label names
      # may contain spaces — so this must NOT truncate at the first word (an
      # `awk '{print $1}'` here would provision "needs" for a label named
      # "needs human review", leaving the real opt-out absent and the hatch broken).
      # Take the whole scalar, then strip: trailing YAML comment (which requires
      # leading whitespace), trailing space, and surrounding quotes.
      opt_out=$(printf '%s' "$opt_out_raw" \
                | sed -n 's/^[[:space:]]*opt_out_label:[[:space:]]*//p' | head -1 \
                | tr -d '\r' \
                | sed -e 's/[[:space:]]\{1,\}#.*$//' \
                      -e 's/[[:space:]]*$//' \
                      -e 's/^"\(.*\)"$/\1/' \
                      -e "s/^'\(.*\)'$/\1/")
    else
      # The convention fallback below is a GUESS. §4 rule 4 makes <id>:hands-off
      # only a convention — the schema lets a persona declare any opt_out_label —
      # so if the manifest is unreadable we may create a label nobody uses while
      # the real one stays absent, leaving opt-out silently broken. Emit it (it is
      # the best guess) but do not call the run a success.
      warn "  Could not read personas/$id/persona.yml — guessing '$id:hands-off' from the convention"
      opt_out=""
      rc=1
    fi
    [ -z "$opt_out" ] && opt_out="$id:hands-off"
    printf '%s|%s|Opt an item out of the %s persona automation entirely\n' \
      "$opt_out" "$PERSONA_OPT_OUT_COLOR" "$id"
  done <<< "$ids"
  return "$rc"
}

apply_labels() {
  local repo="$1"
  info "Applying standard labels to $ORG/$repo ..."

  # Format: "name|color|description" — matches standards/github-settings.md#labels--standard-set
  local label_configs=(
    "security|d93f0b|Security-related PRs and issues"
    "dependencies|0075ca|Dependency update PRs"
    "scorecard|d93f0b|OpenSSF Scorecard findings"
    "bug|d73a4a|Bug reports"
    "enhancement|a2eeef|Feature requests"
    "documentation|0075ca|Documentation changes"
    "in-progress|fbca04|An agent is actively working this issue"
  )

  # Append the derived persona opt-out family (<id>:hands-off, one per persona).
  # Cache on first call so --all mode doesn't re-fetch all manifests per repo.
  #
  # Captured with $( ) rather than `mapfile < <(...)`: process substitution runs
  # the function in a subshell whose EXIT CODE is unreachable (mapfile reports its
  # own status), so a failure there could never be seen — which is exactly how the
  # fail-open survived review. $( ) is also a subshell, but its status propagates.
  if [ "$_PERSONA_OPT_OUT_CONFIGS_CACHED" != true ]; then
    local persona_out=""
    if persona_out=$(persona_opt_out_label_configs); then
      # Cache only a GOOD derivation. Caching a failure would mean a transient
      # error on the first repo of an --all sweep denies opt-out labels to every
      # LATER repo too, even once the API recovers — turning one blip into a
      # fleet-wide gap. Retrying costs a few API calls on the failure path only.
      _PERSONA_OPT_OUT_CONFIGS_CACHED=true
    else
      # Sticky by design: the repo we just processed went without its opt-out
      # labels, so the RUN did not do what it claims even if later repos recover.
      _PERSONA_OPT_OUT_SYNC_FAILED=true
    fi
    _PERSONA_OPT_OUT_CONFIGS_CACHE=()
    # Guard the empty case: `mapfile <<< ""` yields one empty element, which would
    # become a bogus "||" label config.
    if [ -n "$persona_out" ]; then
      mapfile -t _PERSONA_OPT_OUT_CONFIGS_CACHE <<< "$persona_out"
    fi
  fi
  if [ "${#_PERSONA_OPT_OUT_CONFIGS_CACHE[@]}" -gt 0 ]; then
    label_configs+=("${_PERSONA_OPT_OUT_CONFIGS_CACHE[@]}")
  fi

  for config in "${label_configs[@]}"; do
    IFS='|' read -r name color description <<< "$config"
    if [ "$DRY_RUN" = "true" ]; then
      skip "DRY_RUN=true — would create/update label '$name' (#$color) in $ORG/$repo"
    else
      gh label create "$name" \
        --repo "$ORG/$repo" \
        --description "$description" \
        --color "$color" \
        --force 2>/dev/null && ok "  label '$name' applied" || err "  failed to apply label '$name'"
    fi
  done
}

apply_settings() {
  local repo="$1"
  local repo_json="$2"
  info "Applying standard settings to $ORG/$repo ..."

  # Extract current settings from the pre-fetched repo JSON
  local current
  current=$(echo "$repo_json" | jq '{
    allow_auto_merge: .allow_auto_merge,
    delete_branch_on_merge: .delete_branch_on_merge,
    allow_squash_merge: .allow_squash_merge,
    allow_merge_commit: .allow_merge_commit,
    allow_rebase_merge: .allow_rebase_merge,
    has_discussions: .has_discussions,
    has_issues: .has_issues,
    squash_merge_commit_title: .squash_merge_commit_title,
    squash_merge_commit_message: .squash_merge_commit_message
  }' 2>/dev/null || echo "{}")

  if [ "$current" = "{}" ] || [ "$current" = "null" ]; then
    err "Could not parse settings for $ORG/$repo"
    return 1
  fi

  # Standard settings from standards/github-settings.md#repository-settings--standard-defaults
  declare -A EXPECTED=(
    [allow_auto_merge]="true"
    [delete_branch_on_merge]="true"
    [allow_squash_merge]="true"
    [allow_merge_commit]="true"
    [allow_rebase_merge]="true"
    [has_discussions]="true"
    [has_issues]="true"
  )

  local needs_patch=false
  local patch_args=()

  for key in "${!EXPECTED[@]}"; do
    local actual
    actual=$(printf '%s' "$current" | jq -r --arg key "$key" '.[$key] | if . == null then "null" else tostring end')
    local expected="${EXPECTED[$key]}"

    if [ "$actual" != "$expected" ]; then
      info "  $key: $actual → $expected"
      needs_patch=true
      patch_args+=(-F "$key=$expected")
    else
      ok "  $key: already $actual"
    fi
  done

  # Check string settings separately (jq -f flag for strings)
  local squash_title
  squash_title=$(printf '%s' "$current" | jq -r '.squash_merge_commit_title // "null"')
  if [ "$squash_title" != "PR_TITLE" ]; then
    info "  squash_merge_commit_title: $squash_title → PR_TITLE"
    needs_patch=true
    patch_args+=(-f squash_merge_commit_title=PR_TITLE)
  else
    ok "  squash_merge_commit_title: already PR_TITLE"
  fi

  local squash_msg
  squash_msg=$(printf '%s' "$current" | jq -r '.squash_merge_commit_message // "null"')
  if [ "$squash_msg" != "COMMIT_MESSAGES" ]; then
    info "  squash_merge_commit_message: $squash_msg → COMMIT_MESSAGES"
    needs_patch=true
    patch_args+=(-f squash_merge_commit_message=COMMIT_MESSAGES)
  else
    ok "  squash_merge_commit_message: already COMMIT_MESSAGES"
  fi

  if [ "$needs_patch" = false ]; then
    ok "$ORG/$repo is already fully compliant — no changes needed"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    skip "DRY_RUN=true — skipping PATCH for $ORG/$repo"
    return 0
  fi

  gh api -X PATCH "repos/$ORG/$repo" "${patch_args[@]}" > /dev/null
  ok "$ORG/$repo settings updated successfully"
}

# ---------------------------------------------------------------------------
# apply_codeql_default_setup — enable GitHub-managed CodeQL default setup
#
# Per standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup,
# CodeQL is configured via the code-scanning/default-setup endpoint, not a
# per-repo workflow file. Languages are auto-detected from the default branch.
#
# Idempotent: if state is already "configured", we no-op. If "not-configured",
# we PATCH to enable. Repos listed in CODEQL_ADVANCED_EXCEPTIONS are skipped
# (they are approved to keep an inline codeql.yml; see the escape hatch in
# ci-standards.md §2). The API rejects updates on repos without code scanning
# capability (e.g. private repos without GHAS); we log a warning and continue
# so that --all runs are not blocked by a single unsupported repo.
# ---------------------------------------------------------------------------

# Repos approved for advanced CodeQL setup (inline codeql.yml).
# Each entry must have a corresponding standards PR documenting the exception.
CODEQL_ADVANCED_EXCEPTIONS=()

apply_codeql_default_setup() {
  local repo="$1"
  info "Configuring CodeQL default setup for $ORG/$repo ..."

  # Skip repos approved for advanced (inline workflow) CodeQL setup.
  for exception in "${CODEQL_ADVANCED_EXCEPTIONS[@]}"; do
    if [ "$repo" = "$exception" ]; then
      skip "  $repo is in CODEQL_ADVANCED_EXCEPTIONS — skipping default setup"
      return 0
    fi
  done

  local current_state
  current_state=$(gh api "repos/$ORG/$repo/code-scanning/default-setup" --jq '.state' 2>/dev/null || echo "")

  if [ "$current_state" = "configured" ]; then
    ok "  CodeQL default setup already configured"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    skip "DRY_RUN=true — would enable CodeQL default setup (current state: ${current_state:-unknown})"
    return 0
  fi

  local api_err
  if api_err=$(gh api -X PATCH "repos/$ORG/$repo/code-scanning/default-setup" \
       -F state=configured \
       -F query_suite=default 2>&1); then
    ok "  CodeQL default setup enabled"
  else
    # Non-fatal: log warning and continue so --all runs are not blocked by
    # repos that lack code scanning capability (private without GHAS,
    # archived, or empty default branch).
    warn "  Failed to enable CodeQL default setup for $repo — manual review required. API response: $api_err"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# apply_check_suite_prefs — disable auto-trigger check suites for Claude and
# CodeRabbit. Without this, GitHub auto-creates "queued" suites on every push
# that are never completed, permanently blocking auto-merge.
# ---------------------------------------------------------------------------
apply_check_suite_prefs() {
  local repo="$1"
  info "Configuring check-suite auto-trigger preferences for $ORG/$repo ..."

  # GET 404s when prefs have never been set — treat as needing PATCH, don't bail.
  local prefs all_disabled=true
  if prefs=$(gh api "repos/$ORG/$repo/check-suites/preferences" 2>&1); then
    for app_id in "${CHECK_SUITE_APP_IDS[@]}"; do
      local setting
      setting=$(jq -r --argjson id "$app_id" \
        '.preferences.auto_trigger_checks // [] | map(select(.app_id == $id)) | first | .setting | if . == null then "missing" else . end' <<< "$prefs")
      # "missing" means the app has never run in this repo — no orphaned suite possible, skip
      if [ "$setting" != "false" ] && [ "$setting" != "missing" ]; then
        all_disabled=false
      fi
    done
  else
    info "  Could not read current prefs (will apply PATCH anyway). Response: $prefs"
    all_disabled=false
  fi

  if [ "$all_disabled" = true ]; then
    ok "$ORG/$repo check-suite prefs already correct"
    return 0
  fi

  if [ "${DRY_RUN:-false}" = "true" ]; then
    skip "DRY_RUN — skipping check-suite prefs PATCH for $repo"
    return 0
  fi

  local payload
  payload=$(printf '%s\n' "${CHECK_SUITE_APP_IDS[@]}" | \
    jq -Rs 'split("\n") | map(select(. != "")) | map(tonumber) |
             {"auto_trigger_checks": map({"app_id": ., "setting": false})}')

  local api_err
  if api_err=$(gh api -X PATCH "repos/$ORG/$repo/check-suites/preferences" \
       --input - <<< "$payload" 2>&1 >/dev/null); then
    ok "  auto-trigger disabled for app_ids: ${CHECK_SUITE_APP_IDS[*]}"
  else
    # The check-suites/preferences endpoint is legacy: it only accepts a CLASSIC
    # PAT (or GitHub App) with repo-admin. Fine-grained PATs and GITHUB_TOKEN get
    # a 403 here. When the configured token lacks that capability we cannot apply
    # this preference — skip it (loudly) rather than failing the whole settings
    # run, which was reporting apply-repo-settings as 100%-failed fleet-wide while
    # every other setting applied fine. The token-config fix is tracked in
    # combsmith/.github-private#1209; until then this preference is not applied.
    local re_403='"status":[[:space:]]*"?403'
    if [[ "${api_err,,}" =~ $re_403 || "${api_err,,}" =~ "http 403" || "${api_err,,}" =~ "authenticate with a personal access token" ]]; then
      warn "  Skipping check-suite prefs for $repo — token lacks repo-admin for the check-suites API (403). Tracking: combsmith/.github-private#1209"
      return 0
    fi
    err "  PATCH failed for $repo. API response: $api_err"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
if [ $# -eq 0 ]; then
  usage
fi

if [ -z "${GH_TOKEN:-}" ]; then
  err "GH_TOKEN is required — provide a personal access token or GitHub App token with admin:repo scope"
  exit 1
fi

export GH_TOKEN

if [ "$1" = "--all" ]; then
  info "Fetching all non-archived repos in $ORG ..."
  repos=$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)

  if [ -z "$repos" ]; then
    err "No repositories found in $ORG — check GH_TOKEN permissions"
    exit 1
  fi

  failed=0
  for repo in $repos; do
    # Fetch full repo JSON once and share across functions
    repo_json=$(gh api "repos/$ORG/$repo" 2>/dev/null || echo "{}")
    if [ "$repo_json" = "{}" ]; then
      err "Could not fetch settings for $ORG/$repo — check token permissions and repo name"
      failed=$((failed + 1))
      continue
    fi

    apply_settings "$repo" "$repo_json" || failed=$((failed + 1))
    apply_labels "$repo"
    pp_apply_security_and_analysis "$repo" || failed=$((failed + 1))
    apply_codeql_default_setup "$repo" || failed=$((failed + 1))
    apply_check_suite_prefs "$repo" || failed=$((failed + 1))
  done

  if [ "$failed" -gt 0 ]; then
    err "$failed repo(s) failed — check output above for details"
    exit 1
  fi

  # The persona opt-out family is the escape hatch §4 rule 4 mandates. If it could
  # not be derived faithfully, the static labels still landed — but this run did
  # NOT do what it claims, and saying so is the whole point (#755).
  if [ "$_PERSONA_OPT_OUT_SYNC_FAILED" = true ]; then
    err "persona opt-out labels could not be derived faithfully — static labels applied, but the <id>:hands-off family is incomplete or guessed"
    exit 1
  fi

  ok "All repos processed successfully"
else
  repo_json=$(gh api "repos/$ORG/$1" 2>/dev/null || echo "{}")
  if [ "$repo_json" = "{}" ]; then
    err "Could not fetch settings for $ORG/$1 — check token permissions and repo name"
    exit 1
  fi

  apply_settings "$1" "$repo_json"
  apply_labels "$1"
  pp_apply_security_and_analysis "$1"
  apply_codeql_default_setup "$1"
  apply_check_suite_prefs "$1"

  # Same guard as --all: a single-repo run must not exit 0 while the mandated
  # opt-out hatch is missing from that repo.
  if [ "$_PERSONA_OPT_OUT_SYNC_FAILED" = true ]; then
    err "persona opt-out labels could not be derived faithfully — static labels applied, but the <id>:hands-off family is incomplete or guessed"
    exit 1
  fi
fi
}

# Run main only when executed directly, not when sourced (e.g. by the bats suite).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
