#!/usr/bin/env bash
# Org-wide CodeQL (code scanning) audit → idempotent GitHub issues.
#
# Reads every org repo's open CodeQL alerts, groups them per (GitHub repo ×
# rule family), and creates/updates/closes one GitHub issue per group. Issues
# carry:
#   - dev-lead            → autonomous remediation pickup (all groups)
#   - codeql-audit        → marker label for idempotent listing/closing
#   - priority:<severity> → prioritization from the group's worst alert severity
#   - security            → when any alert in the group is a security alert
#
# Idempotency: one issue per (repo, family), keyed by a hidden body marker and
# titled "CodeQL: <family title>". Re-runs update the body/comment and
# re-trigger dev-lead on persistent alerts; groups that drop to zero are
# auto-closed. A repo whose alerts could not be read is never auto-closed.
#
# No duplicates with the other audits: alerts for problems another audit
# already files (or that policy deliberately accepts) are suppressed — counted
# in the summary, never filed. See suppression_reason().
#
# Env:
#   ORG            GitHub owner                              (default: combsmith)
#   REPORT_DIR     output dir                                (default: mktemp -d)
#   TARGET_REPO    limit to one repo (owner/name or name); blank = all
#   DRY_RUN        "true" → scan + report, no issue writes   (default: false)
#   CREATE_ISSUES  "true" → manage issues                    (default: true)
#
# Standard: standards/ci-standards.md#codeql-audit-codeql-audityml
set -euo pipefail

ORG="${ORG:-combsmith}"
CODEQL_AUDIT_LABEL="codeql-audit"
DRY_RUN="${DRY_RUN:-false}"
CREATE_ISSUES="${CREATE_ISSUES:-true}"
TARGET_REPO="${TARGET_REPO:-}"
REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"

FINDINGS_FILE="$REPORT_DIR/findings.json"
SUPPRESSED_FILE="$REPORT_DIR/suppressed.json"
GROUPS_FILE="$REPORT_DIR/groups.json"
SCANNED_FILE="$REPORT_DIR/scanned-repos.txt"
INCONCLUSIVE_FILE="$REPORT_DIR/inconclusive-repos.txt"
SUMMARY_FILE="$REPORT_DIR/summary.md"
COUNTS_FILE="$REPORT_DIR/issue-counts.json"

ISSUES_ADDED=0
ISSUES_EXISTING=0
ISSUES_RETRIGGERED=0
ISSUES_REMOVED=0

# Shared dev-lead retrigger helpers — dl_dev_lead_active() and
# dl_cycle_trigger_label(). Only sourced when present (skipped under bats).
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dev-lead-retrigger.sh"
# shellcheck source=/dev/null
[ -f "$_LIB" ] && source "$_LIB"

info() { echo "[info] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested via bats; keep free of side effects)
# ---------------------------------------------------------------------------

# Classify a CodeQL rule id ("<pack>/<query>") into a stable family: the query
# pack's language. One issue per language per repo is one remediation PR.
classify_family() {
  case "${1%%/*}" in
    actions)          echo "actions" ;;
    js)               echo "js" ;;
    py)               echo "py" ;;
    go)               echo "go" ;;
    java)             echo "java" ;;
    cs)               echo "csharp" ;;
    cpp|c)            echo "cpp" ;;
    rb)               echo "ruby" ;;
    swift)            echo "swift" ;;
    rust)             echo "rust" ;;
    *)                echo "misc" ;;
  esac
}

# Human-readable title for a family (used verbatim in the issue title).
family_title() {
  case "$1" in
    actions) echo "GitHub Actions workflow security" ;;
    js)      echo "JavaScript/TypeScript alerts" ;;
    py)      echo "Python alerts" ;;
    go)      echo "Go alerts" ;;
    java)    echo "Java/Kotlin alerts" ;;
    csharp)  echo "C# alerts" ;;
    cpp)     echo "C/C++ alerts" ;;
    ruby)    echo "Ruby alerts" ;;
    swift)   echo "Swift alerts" ;;
    rust)    echo "Rust alerts" ;;
    *)       echo "miscellaneous alerts" ;;
  esac
}

# Why an alert must NOT be filed, or nothing when it should be.
# args: <rule_id> <alert message> <file_path>
#
# - actions/unpinned-tag on a first-party ORG ref: the org pins its own reusable
#   workflows to moving channel tags on purpose (ci-standards.md § Exception:
#   Internal Reusable Workflow References). Filing it would send dev-lead to
#   SHA-pin a ref the standard forbids SHA-pinning.
# - actions/unpinned-tag on anything else: compliance-audit.sh
#   check_action_pinning already files `Compliance: unpinned-actions-<wf>`.
# - actions/missing-workflow-permissions: suppress only for regular workflows in
#   .github/workflows/ (not reusable-*). Uncovered workflows and reusable workflows
#   are reported.
suppression_reason() {
  local rule="$1" message="${2:-}" file="${3:-}"
  case "$rule" in
    actions/unpinned-tag)
      if [[ "$message" == *"'${ORG}/"* ]]; then
        echo "first-party channel ref (exempt by ci-standards.md)"
      else
        echo "filed by compliance audit (unpinned-actions)"
      fi ;;
    actions/missing-workflow-permissions)
      if [[ "$file" == .github/workflows/*.y*ml && "$file" != *-reusable.y*ml ]]; then
        echo "filed by compliance audit (missing-permissions)"
      fi ;;
  esac
}

# Normalized severity of one alert: the security severity when the query has
# one (critical|high|medium|low), else the rule severity (error|warning|note).
# args: <security_severity_level or ""> <rule severity or "">
alert_severity() {
  local sec="${1:-}" rule="${2:-}"
  case "$sec" in
    critical|high|medium|low) echo "$sec"; return ;;
  esac
  case "$rule" in
    error|warning|note) echo "$rule" ;;
    *)                  echo "note" ;;
  esac
}

# Numeric rank for a normalized severity (higher = worse). A security severity
# outranks any non-security rule severity of the same weight.
severity_rank() {
  case "$1" in
    critical) echo 7 ;;
    high)     echo 6 ;;
    medium)   echo 5 ;;
    error)    echo 4 ;;
    low)      echo 3 ;;
    warning)  echo 2 ;;
    note)     echo 1 ;;
    *)        echo 0 ;;
  esac
}

# Map a normalized severity → the org's shared priority scale (the same labels
# the SonarCloud audit uses, so one triage view covers both tools).
severity_priority_label() {
  case "$1" in
    critical)     echo "priority:blocker" ;;
    high)         echo "priority:critical" ;;
    medium|error) echo "priority:major" ;;
    low|warning)  echo "priority:minor" ;;
    note)         echo "priority:info" ;;
    *)            echo "priority:minor" ;;
  esac
}

# Stable idempotency key, embedded as a hidden HTML comment in each issue body.
# args: <repo> <family>
issue_marker() {
  echo "<!-- codeql-audit:key=$1/$2 -->"
}

# Classify a failed alerts-API response. Echo "none" when the repo simply has
# no CodeQL analysis (code scanning never ran → zero alerts, a real result) and
# "error" for anything else (auth, rate limit, GHAS off) → repo inconclusive.
# args: <response body or gh error text>
alerts_error_kind() {
  case "$1" in
    *"no analysis found"*|*"No analysis found"*) echo "none" ;;
    *)                                           echo "error" ;;
  esac
}

# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

# Echo the open CodeQL alerts of one repo as a JSON array, or return 1 when the
# read failed (the repo is then inconclusive: no issue is closed for it).
repo_open_alerts() {
  local repo="$1" out err
  err=$(mktemp)
  if out=$(gh api --paginate \
      "repos/$ORG/$repo/code-scanning/alerts?state=open&tool_name=CodeQL&per_page=100" \
      2>"$err"); then
    rm -f "$err"
    # --paginate emits one array per page; merge them.
    echo "$out" | jq -s 'add // []'
    return 0
  fi
  local msg
  msg="$(cat "$err") $out"
  rm -f "$err"
  if [ "$(alerts_error_kind "$msg")" = "none" ]; then
    echo "[]"
    return 0
  fi
  warn "$repo: code-scanning alerts unreadable — $(echo "$msg" | tr '\n' ' ' | cut -c1-200)"
  return 1
}

list_repos() {
  if [ -n "$TARGET_REPO" ]; then
    echo "${TARGET_REPO#"$ORG/"}"
    return
  fi
  gh repo list "$ORG" --no-archived --limit 200 --json name -q '.[].name'
}

# ---------------------------------------------------------------------------
# Scan: findings.json (to file), suppressed.json, then groups.json
# ---------------------------------------------------------------------------
scan() {
  local ndjson="$REPORT_DIR/alerts.ndjson"
  : > "$ndjson"; : > "$SCANNED_FILE"; : > "$INCONCLUSIVE_FILE"

  local repos repo alerts
  repos=$(list_repos) || { warn "could not list repos for $ORG"; return 1; }
  for repo in $repos; do
    info "Scanning $repo"
    if ! alerts=$(repo_open_alerts "$repo"); then
      echo "$repo" >> "$INCONCLUSIVE_FILE"
      continue
    fi
    echo "$repo" >> "$SCANNED_FILE"

    local row rule msg sec rsev file
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      rule=$(jq -r '.rule.id // ""' <<< "$row")
      msg=$(jq -r '.most_recent_instance.message.text // ""' <<< "$row")
      sec=$(jq -r '.rule.security_severity_level // ""' <<< "$row")
      rsev=$(jq -r '.rule.severity // ""' <<< "$row")
      file=$(jq -r '.most_recent_instance.location.path // ""' <<< "$row")
      jq -c --arg repo "$repo" --arg family "$(classify_family "$rule")" \
         --arg severity "$(alert_severity "$sec" "$rsev")" \
         --arg suppressed "$(suppression_reason "$rule" "$msg" "$file")" '
        {repo:$repo, family:$family, severity:$severity, suppressed:$suppressed,
         number:.number, url:.html_url, rule:(.rule.id // ""),
         rule_name:(.rule.description // .rule.name // ""),
         security:((.rule.security_severity_level // "") != ""
                    or ((.rule.tags // []) | index("security") != null)),
         file:(.most_recent_instance.location.path // ""),
         line:(.most_recent_instance.location.start_line // 0)}' <<< "$row" >> "$ndjson"
    done < <(jq -c '.[]' <<< "$alerts")
  done

  local all='[]'
  [ -s "$ndjson" ] && all=$(jq -s '.' "$ndjson")
  jq '[.[] | select(.suppressed == "")]' <<< "$all" > "$FINDINGS_FILE"
  jq '[.[] | select(.suppressed != "")]' <<< "$all" > "$SUPPRESSED_FILE"

  jq '
    def rank: {"critical":7,"high":6,"medium":5,"error":4,"low":3,"warning":2,"note":1}[.] // 0;
    sort_by(.repo, .family) | group_by([.repo, .family])
    | map({
        repo: .[0].repo,
        family: .[0].family,
        count: length,
        has_security: any(.[]; .security),
        max_severity: (max_by(.severity | rank) | .severity),
        rules: (group_by(.rule) | map({rule: .[0].rule, name: .[0].rule_name,
                 count: length, severity: (max_by(.severity | rank) | .severity)})
                | sort_by(-(.severity | rank), -.count)),
        alerts: (sort_by(-(.severity | rank), .file, .line)
                 | map({number, url, rule, file, line, severity}))
      })
  ' "$FINDINGS_FILE" > "$GROUPS_FILE"

  if [ ! -s "$SCANNED_FILE" ] && [ -s "$INCONCLUSIVE_FILE" ]; then
    warn "no repo's code-scanning alerts could be read — check the token's code-scanning (security_events) read access"
  fi
}

# ---------------------------------------------------------------------------
# Issue management
# ---------------------------------------------------------------------------

# Create labels only when missing: the priority:* and security labels are
# shared with the SonarCloud audit and the standard label set, so this never
# overwrites their colour or description (no --force).
ensure_labels() {
  local repo="$1"
  local specs=(
    "codeql-audit|0e4a8f|CodeQL audit finding (idempotent marker)"
    "dev-lead|8B5CF6|For dev-lead agent pickup"
    "security|d93f0b|Security-related PRs and issues"
    "priority:blocker|b60205|Blocker severity"
    "priority:critical|d93f0b|Critical severity"
    "priority:major|fbca04|Major severity"
    "priority:minor|0e8a16|Minor severity"
    "priority:info|c5def5|Informational severity"
  )
  local name color desc
  for spec in "${specs[@]}"; do
    IFS='|' read -r name color desc <<< "$spec"
    gh label create "$name" --repo "$ORG/$repo" --color "$color" \
      --description "$desc" 2>/dev/null || true
  done
}

render_body() {
  local group="$1"
  local repo family count max_sev title
  repo=$(jq -r '.repo' <<< "$group")
  family=$(jq -r '.family' <<< "$group")
  count=$(jq -r '.count' <<< "$group")
  max_sev=$(jq -r '.max_severity' <<< "$group")
  title=$(family_title "$family")

  local rules_tbl alerts_list more
  rules_tbl=$(jq -r --arg base "https://github.com/$ORG/$repo/security/code-scanning" '
    .rules[] | "| [`\(.rule)`](\($base)?query=is%3Aopen+tool%3ACodeQL+rule%3A\(.rule | @uri)) | \(.severity) | \(.count) | \((.name // "")[0:90] | gsub("\\|";"\\\\|")) |"' <<< "$group")
  alerts_list=$(jq -r '.alerts[0:30][] | "- [#\(.number)](\(.url)) `\(.file):\(.line)` — `\(.rule)` (\(.severity))"' <<< "$group")
  more=$(jq -r 'if (.alerts | length) > 30 then "- …and \((.alerts | length) - 30) more" else "" end' <<< "$group")

  cat <<BODY
## CodeQL: ${title}

**${count}** open CodeQL alert(s) in \`${ORG}/${repo}\`, worst severity **${max_sev}**. Generated by the org [CodeQL Audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/codeql-audit.yml).

[View in code scanning →](https://github.com/${ORG}/${repo}/security/code-scanning?query=is%3Aopen+tool%3ACodeQL)

### Rules
| Rule | Worst severity | Alerts | Description |
|---|---|---:|---|
${rules_tbl}

### Alerts
${alerts_list}
${more}

### Priority
Labeled \`$(severity_priority_label "$max_sev")\` — mapped from this group's worst alert severity (\`${max_sev}\`).

### Acceptance
- [ ] Every alert above fixed in code, so CodeQL closes it on the next default-branch scan
- [ ] No behavior change; CI green
- [ ] Dismiss an alert only when it is a confirmed false positive, with the reason in the dismissal comment

---
*Idempotent issue — updated automatically each audit run; auto-closed when the group has no open alerts.*

$(issue_marker "$repo" "$family")
BODY
}

manage_group_issue() {
  local group="$1"
  local repo family stable_title max_sev prio labels
  repo=$(jq -r '.repo' <<< "$group")
  family=$(jq -r '.family' <<< "$group")
  max_sev=$(jq -r '.max_severity' <<< "$group")
  stable_title="CodeQL: $(family_title "$family")"
  prio=$(severity_priority_label "$max_sev")

  labels="$CODEQL_AUDIT_LABEL,dev-lead,$prio"
  [ "$(jq -r '.has_security' <<< "$group")" = "true" ] && labels="$labels,security"

  if [ "$DRY_RUN" = "true" ] || [ "$CREATE_ISSUES" != "true" ]; then
    info "[dry-run] $repo :: $stable_title [$labels] ($(jq -r '.count' <<< "$group") alert(s))"
    return
  fi

  local body
  body=$(render_body "$group")
  ensure_labels "$repo"

  local existing marker list
  marker="codeql-audit:key=${repo}/${family}"
  if ! list=$(gh issue list --repo "$ORG/$repo" --label "$CODEQL_AUDIT_LABEL" --state open \
    --json number,body --limit 200); then
    warn "$repo: could not list issues, skipping $stable_title"; return
  fi
  existing=$(jq -r --arg m "$marker" '.[] | select((.body // "") | contains($m)) | .number' <<< "$list" || echo "")
  existing=$(head -1 <<< "$existing")

  if [ -n "$existing" ]; then
    gh issue edit "$existing" --repo "$ORG/$repo" --body "$body" \
      --add-label "$prio" 2>/dev/null || true
    [ "$(jq -r '.has_security' <<< "$group")" = "true" ] && \
      gh issue edit "$existing" --repo "$ORG/$repo" --add-label "security" 2>/dev/null || true
    local other
    for other in priority:blocker priority:critical priority:major priority:minor priority:info; do
      [ "$other" != "$prio" ] && gh issue edit "$existing" --repo "$ORG/$repo" \
        --remove-label "$other" 2>/dev/null || true
    done
    gh issue comment "$existing" --repo "$ORG/$repo" \
      --body "**CodeQL Audit** ($(date -u +%Y-%m-%d)): still open — $(jq -r '.count' <<< "$group") alert(s), worst severity \`${max_sev}\`." 2>/dev/null || true
    ISSUES_EXISTING=$((ISSUES_EXISTING + 1))
    info "Updated #$existing in $repo :: $stable_title"

    if declare -f dl_dev_lead_active >/dev/null 2>&1 && dl_dev_lead_active "$ORG" "$repo" "$existing"; then
      info "#$existing in $repo — dev-lead already active, not re-triggering"
    elif declare -f dl_cycle_trigger_label >/dev/null 2>&1 && dl_cycle_trigger_label "$ORG" "$repo" "$existing" "dev-lead" "$DRY_RUN"; then
      ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
    else
      gh issue edit "$existing" --repo "$ORG/$repo" --add-label "dev-lead" 2>/dev/null || true
    fi
    return
  fi

  local url
  url=$(gh issue create --repo "$ORG/$repo" --title "$stable_title" \
    --label "$labels" --body "$body" 2>/dev/null || echo "")
  if [ -n "$url" ]; then
    ISSUES_ADDED=$((ISSUES_ADDED + 1))
    info "Created $url"
  else
    warn "Failed to create issue in $repo :: $stable_title"
  fi
}

# Close audit issues whose (repo, family) group has no open alerts. Only called
# for repos whose alerts were read successfully this run.
close_resolved() {
  local repo="$1"
  local open_issues
  open_issues=$(gh issue list --repo "$ORG/$repo" --label "$CODEQL_AUDIT_LABEL" --state open \
    --json number,body --limit 200 2>/dev/null \
    | jq -r '.[] | "\(.number)\t" + ((.body // "") | (try (capture("codeql-audit:key=[^/]+/(?<fam>[a-z0-9]+)").fam) catch ""))' 2>/dev/null || echo "")
  [ -z "$open_issues" ] && return

  local current_fams
  current_fams=$(jq -r --arg repo "$repo" '.[] | select(.repo == $repo) | .family' "$GROUPS_FILE")

  local num fam
  while IFS=$'\t' read -r num fam; do
    [ -z "$num" ] && continue
    [ -z "$fam" ] && continue   # not a marker-bearing audit issue — leave it alone
    if ! grep -qxF "$fam" <<< "$current_fams"; then
      gh issue close "$num" --repo "$ORG/$repo" \
        --comment "Resolved! No open CodeQL alerts remain in this group as of $(date -u +%Y-%m-%d). Closing automatically." 2>/dev/null \
        && { ISSUES_REMOVED=$((ISSUES_REMOVED + 1)); info "Closed resolved #$num in $repo"; } || true
    fi
  done <<< "$open_issues"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
generate_summary() {
  local total suppressed scanned inconclusive
  total=$(jq 'length' "$FINDINGS_FILE")
  suppressed=$(jq 'length' "$SUPPRESSED_FILE")
  scanned=$(grep -c . "$SCANNED_FILE" || true)
  inconclusive=$(grep -c . "$INCONCLUSIVE_FILE" || true)

  {
    echo "# CodeQL Audit — $(date -u +%Y-%m-%d)"
    echo ""
    echo "**Org:** \`${ORG}\` · **Repos scanned:** ${scanned} · **Open alerts filed:** ${total} · **Suppressed:** ${suppressed} · **Inconclusive repos:** ${inconclusive}"
    if [ "$inconclusive" -gt 0 ]; then
      echo ""
      echo "> [!WARNING]"
      echo "> Alerts could not be read for: $(paste -sd ',' "$INCONCLUSIVE_FILE" | sed 's/,/, /g'). Their issues were left untouched (not updated, not closed)."
    fi
    echo ""
    echo "## By repo × family (one issue each)"
    echo "| Repo | Family | Alerts | Worst severity | Priority |"
    echo "|---|---|---:|---|---|"
    local g r f c s
    while IFS= read -r g; do
      r=$(jq -r '.repo' <<< "$g"); f=$(family_title "$(jq -r '.family' <<< "$g")")
      c=$(jq -r '.count' <<< "$g"); s=$(jq -r '.max_severity' <<< "$g")
      echo "| $r | $f | $c | $s | $(severity_priority_label "$s") |"
    done < <(jq -c '.[]' "$GROUPS_FILE")
    echo ""
    echo "## Suppressed (not filed — tracked elsewhere or exempt by policy)"
    echo "| Rule | Reason | Alerts |"
    echo "|---|---|---:|"
    jq -r 'group_by([.rule, .suppressed]) | .[] | "| `\(.[0].rule)` | \(.[0].suppressed) | \(length) |"' "$SUPPRESSED_FILE"
    echo ""
    echo "## Issue actions"
    echo "| Action | Count |"
    echo "|---|---:|"
    echo "| Added | $ISSUES_ADDED |"
    echo "| Updated | $ISSUES_EXISTING |"
    echo "| dev-lead re-triggered | $ISSUES_RETRIGGERED |"
    echo "| Closed (resolved) | $ISSUES_REMOVED |"
    echo ""
    echo "---"
    echo "*Generated by the CodeQL Audit workflow.*"
  } > "$SUMMARY_FILE"
}

# ---------------------------------------------------------------------------
main() {
  mkdir -p "$REPORT_DIR"
  info "CodeQL audit — org=$ORG dry_run=$DRY_RUN create_issues=$CREATE_ISSUES target=${TARGET_REPO:-all}"
  scan

  local group repo
  while IFS= read -r group; do
    manage_group_issue "$group"
  done < <(jq -c '.[]' "$GROUPS_FILE")

  if [ "$CREATE_ISSUES" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    while IFS= read -r repo; do
      [ -n "$repo" ] && close_resolved "$repo"
    done < "$SCANNED_FILE"
  fi

  jq -n --argjson added "$ISSUES_ADDED" --argjson existing "$ISSUES_EXISTING" \
        --argjson retriggered "$ISSUES_RETRIGGERED" --argjson removed "$ISSUES_REMOVED" \
        '{added:$added,existing:$existing,retriggered:$retriggered,removed:$removed}' > "$COUNTS_FILE"

  generate_summary
  info "Done. Filed alerts: $(jq length "$FINDINGS_FILE"); suppressed: $(jq length "$SUPPRESSED_FILE"); groups: $(jq length "$GROUPS_FILE"); added=$ISSUES_ADDED existing=$ISSUES_EXISTING removed=$ISSUES_REMOVED"

  # Fail loud on partial coverage so the run shows red, after the summary is
  # written and every readable repo has been handled.
  if [ -s "$INCONCLUSIVE_FILE" ]; then
    warn "$(grep -c . "$INCONCLUSIVE_FILE") repo(s) inconclusive — see summary"
    return 1
  fi
}

# Guard: only run when executed directly (sourcing defines functions for bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
