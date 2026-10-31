#!/usr/bin/env bash
# Org-wide CodeRabbit Deep Scan audit → idempotent GitHub issues.
#
# Reads the org's Deep Scan inventory from the CodeRabbit API as SARIF (the
# paginated JSON format has no findingFingerprint), routes each finding to the
# repo that owns the code, and creates/updates/closes one GitHub issue per
# finding. Issues carry:
#   - coderabbit-audit    → marker label for idempotent listing/closing
#   - needs-verification  → a person has not confirmed this LLM finding yet
#   - security            → every Deep Scan finding is a security finding
#   - priority:<severity> → prioritization from the finding's severity
#
# Never dev-lead: findings are unverified LLM output. A person adds dev-lead
# after confirming the finding; this script neither adds nor removes it.
#
# Public-safe by construction: every org repo is public, so issue bodies, logs,
# the run summary and the uploaded artifact are public. Only allow-listed opaque
# fields (fingerprint, finding id, severity, state, repo) ever leave parse_sarif.
# Description, category, CWE, subsystem, path, line and call stack do not.
#
# Lifecycle: an issue closes only when the export explicitly reports its
# finding as fixed or dismissed. A finding merely absent from the export never
# closes one: the export reflects each repo's latest scan, which may have only
# partial coverage. A failed read or an unexpected export writes nothing.
#
# Env:
#   CODERABBIT_API_KEY  non-agentic key with security:read      (required)
#   ORG                 GitHub owner                            (default: combsmith)
#   REPORT_DIR          output dir                              (default: mktemp -d)
#   TARGET_REPO         limit to one repo (owner/name or name); blank = all
#   MIN_SEVERITY        lowest severity that opens a new issue  (default: low)
#   DRY_RUN             "true" → scan + report, no issue writes (default: false)
#   CODERABBIT_API_URL  API base URL (default: https://api.coderabbit.ai)
#
# Standard: standards/ci-standards.md#coderabbit-audit-coderabbit-audityml
set -euo pipefail

ORG="${ORG:-combsmith}"
CODERABBIT_AUDIT_LABEL="coderabbit-audit"
VERIFY_LABEL="needs-verification"
DRY_RUN="${DRY_RUN:-false}"
TARGET_REPO="${TARGET_REPO:-}"
MIN_SEVERITY="${MIN_SEVERITY:-low}"
CODERABBIT_API_URL="${CODERABBIT_API_URL:-https://api.coderabbit.ai}"
REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"

FINDINGS_FILE="$REPORT_DIR/findings.json"
SUMMARY_FILE="$REPORT_DIR/summary.md"
COUNTS_FILE="$REPORT_DIR/issue-counts.json"

ISSUES_ADDED=0
ISSUES_EXISTING=0
ISSUES_REMOVED=0
BELOW_THRESHOLD=0
NOT_IN_EXPORT=0
UNMAPPED=0
RUN_ERROR=""

info() { echo "[info] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested via bats; keep free of side effects)
# ---------------------------------------------------------------------------

# Lowercase a severity and reject anything outside CodeRabbit's scale, so no
# free text from the export can reach a label, title or body.
normalize_severity() {
  local sev
  sev=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$sev" in
    critical|high|medium|low) echo "$sev" ;;
    *)                        echo "unknown" ;;
  esac
}

# Numeric rank for a normalized severity (higher = worse). An unknown severity
# ranks as medium so a scale change files issues rather than hiding them.
severity_rank() {
  case "$1" in
    critical)       echo 4 ;;
    high)           echo 3 ;;
    medium|unknown) echo 2 ;;
    low)            echo 1 ;;
    *)              echo 2 ;;
  esac
}

# Map a normalized severity → the org's shared priority scale (the same labels
# the CodeQL and SonarCloud audits use, so one triage view covers all three).
severity_priority_label() {
  case "$1" in
    critical)       echo "priority:blocker" ;;
    high)           echo "priority:critical" ;;
    medium|unknown) echo "priority:major" ;;
    low)            echo "priority:minor" ;;
    *)              echo "priority:major" ;;
  esac
}

# findingFingerprint is the idempotency key, so anything but its known shape
# means the export changed and nothing can be tracked safely.
valid_fingerprint() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

# findingId is opaque too, but it is printed in public issues: only a UUID passes.
valid_finding_id() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]
}

# Stable idempotency key, embedded as a hidden HTML comment in each issue body.
issue_marker() {
  echo "<!-- coderabbit-audit:key=$1 -->"
}

# Stable issue title; severity stays out so a re-rating keeps the same title.
issue_title() {
  echo "CodeRabbit Deep Scan: finding ${1:0:12}"
}

# Echo the org repo a caller stub delegates to, or nothing when the workflow is
# not a stub. A stub has no steps of its own, so a finding located in one can
# only have its sink in the called workflow. Call-stack frames cannot decide
# this: CodeRabbit guarantees neither their order nor their grammar. A stub
# calling more than one org repo is ambiguous and echoes nothing.
# args: <org> <workflow file text>
stub_callee_repo() {
  local org="$1" text="$2" callees
  grep -Eq '^[[:space:]]+steps:' <<< "$text" && return 0
  callees=$(grep -E "^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"']?${org}/" <<< "$text" \
    | sed -nE "s#.*${org}/([A-Za-z0-9._-]+)/\.github/workflows/.*#\1#p" \
    | sort -u) || true
  [[ -n "$callees" ]] && [[ "$(grep -c . <<< "$callees")" = "1" ]] && echo "$callees"
  return 0
}

# The repo a finding's issue belongs in. Only a stub under .github/workflows/
# moves a finding away from the repo that was scanned.
# args: <org> <scanned repo> <finding path> <workflow file text or "">
route_owner() {
  local org="$1" scanned="$2" path="$3" text="${4:-}" callee=""
  case "$path" in
    .github/workflows/*.yml|.github/workflows/*.yaml)
      callee=$(stub_callee_repo "$org" "$text") ;;
  esac
  echo "${callee:-$scanned}"
}

# Classify the export's HTTP status into the operator hint for the run log.
api_error_hint() {
  case "$1" in
    401)     echo "invalid or inactive API key" ;;
    403)     echo "key type not allowed, security:read missing, or repo outside the key's scope" ;;
    410)     echo "legacy organization API key: create a current non-agentic key" ;;
    413)     echo "export over 50,000 records or 16 MB: run per repo with TARGET_REPO" ;;
    429)     echo "rate limited" ;;
    *)       echo "unexpected response" ;;
  esac
}

# ---------------------------------------------------------------------------
# CodeRabbit API
# ---------------------------------------------------------------------------

# Download the SARIF inventory to a file. Echoes nothing from the response:
# error bodies come from the export endpoint and logs here are public.
# args: <output file> <repo id or "">
fetch_sarif() {
  local out="$1" repo_id="${2:-}" status url
  url="$CODERABBIT_API_URL/v1/security/scans/code?format=sarif&state=all"
  [[ -n "$repo_id" ]] && url="$url&repo_id=$repo_id"
  # Key on stdin, not argv, so it stays out of the process list.
  if ! status=$(printf 'header = "x-coderabbitai-api-key: %s"\n' "$CODERABBIT_API_KEY" \
      | curl --silent --show-error --location --max-time 180 --retry 3 \
          --config - --output "$out" --write-out '%{http_code}' "$url"); then
    warn "CodeRabbit API request failed"
    return 1
  fi
  if [[ "$status" != "200" ]]; then
    warn "CodeRabbit API returned HTTP $status: $(api_error_hint "$status")"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Parse: the only code that reads finding content
# ---------------------------------------------------------------------------

# Reduce the SARIF to the fields routing and tracking need, as NDJSON. Path and
# revision are for routing only and stay in the private work dir. Fails on any
# result without the expected identity, so a changed export writes nothing.
# args: <sarif file> <output ndjson>
parse_sarif() {
  local sarif="$1" out="$2"
  jq -e '.runs | type == "array"' "$sarif" >/dev/null 2>&1 || {
    warn "export is not SARIF with a runs array"
    return 1
  }
  jq -c '.runs[].results[]? | {
      fingerprint: (.properties.findingFingerprint // ""),
      finding_id: (.properties.findingId // ""),
      severity: (.properties.severity // ""),
      state: (.properties.state // ""),
      repo_id: ((.properties.scanProvenance.scope.primary.repositoryId // "") | tostring),
      revision: (.properties.scanProvenance.scope.primary.revision // ""),
      path: (.locations[0].physicalLocation.artifactLocation.uri // "")
    }' "$sarif" > "$out" || {
    warn "export could not be parsed"
    return 1
  }

  local row fp id state repo_id
  local bad=0
  while IFS= read -r row; do
    fp=$(jq -r '.fingerprint' <<< "$row")
    id=$(jq -r '.finding_id' <<< "$row")
    state=$(jq -r '.state' <<< "$row")
    repo_id=$(jq -r '.repo_id' <<< "$row")
    valid_fingerprint "$fp" || bad=$((bad + 1))
    valid_finding_id "$id" || bad=$((bad + 1))
    [[ "$repo_id" =~ ^[0-9]+$ ]] || bad=$((bad + 1))
    case "$state" in open|fixed|dismissed) ;; *) bad=$((bad + 1)) ;; esac
  done < "$out"
  if [[ "$bad" -gt 0 ]]; then
    warn "export has $bad invalid identity field(s): the export format may have changed"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

# All org repos as NDJSON {id,name,archived}. Repos the token cannot see are not
# listed, so ORG_SCORECARD_TOKEN must cover all repositories (ci-standards.md).
list_org_repos() {
  gh api --paginate "orgs/$ORG/repos?type=all&per_page=100" \
    --jq '.[] | {id: (.id | tostring), name, archived}'
}

# Text of a workflow file at the scanned revision.
# args: <repo> <path> <revision>
read_workflow() {
  gh api "repos/$ORG/$1/contents/$2?ref=$3" --jq '.content' | base64 -d
}

# Create labels only when missing: priority:* and security are shared with the
# other audits and the standard label set (no --force).
ensure_labels() {
  local repo="$1"
  local specs=(
    "$CODERABBIT_AUDIT_LABEL|5c3bd6|CodeRabbit Deep Scan audit finding (idempotent marker)"
    "$VERIFY_LABEL|fbca04|LLM finding not yet confirmed by a person"
    "security|d93f0b|Security-related PRs and issues"
    "priority:blocker|b60205|Blocker severity"
    "priority:critical|d93f0b|Critical severity"
    "priority:major|fbca04|Major severity"
    "priority:minor|0e8a16|Minor severity"
  )
  local name color desc
  for spec in "${specs[@]}"; do
    IFS='|' read -r name color desc <<< "$spec"
    gh label create "$name" --repo "$ORG/$repo" --color "$color" \
      --description "$desc" 2>/dev/null || true
  done
}

# Open audit issues across the org, as NDJSON {fingerprint,repo,number}. Keyed
# org-wide so a finding whose route changes keeps its issue instead of gaining a
# second one. Returns 1 on any failed listing: an incomplete index could file
# duplicates.
# args: <org repo names (newline-separated)> <output ndjson>
build_issue_index() {
  local names="$1" out="$2" repo list failed=0
  : > "$out"
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if ! list=$(gh issue list --repo "$ORG/$repo" --label "$CODERABBIT_AUDIT_LABEL" --state open \
        --json number,body --limit 1000); then
      warn "$repo: could not list audit issues"
      failed=1
      continue
    fi
    jq -c --arg repo "$repo" '.[]
      | ((.body // "") | try capture("coderabbit-audit:key=(?<fp>[0-9a-f]{64})").fp catch "") as $fp
      | select($fp != "")
      | {fingerprint: $fp, repo: $repo, number}' <<< "$list" >> "$out"
  done <<< "$names"
  return "$failed"
}

# ---------------------------------------------------------------------------
# Scan: findings.json (allow-listed fields only)
# ---------------------------------------------------------------------------

# Resolve repo names and routes for every parsed finding. Returns 1 when a
# workflow needed for routing cannot be read: a guessed route could file the
# finding in the wrong public repo.
# args: <parsed ndjson> <org repos ndjson>
resolve_findings() {
  local parsed="$1" repos="$2" row id name archived path revision owner text sev
  local tmp failed=0
  tmp=$(mktemp)
  while IFS= read -r row; do
    id=$(jq -r '.repo_id' <<< "$row")
    name=$(jq -r --arg id "$id" 'select(.id == $id) | .name' "$repos" | head -1)
    archived=$(jq -r --arg id "$id" 'select(.id == $id) | .archived' "$repos" | head -1)
    if [[ -z "$name" ]] || [[ "$archived" = "true" ]]; then
      UNMAPPED=$((UNMAPPED + 1))
      continue
    fi
    path=$(jq -r '.path' <<< "$row")
    revision=$(jq -r '.revision' <<< "$row")
    text=""
    case "$path" in
      .github/workflows/*.yml|.github/workflows/*.yaml)
        if ! text=$(read_workflow "$name" "$path" "$revision"); then
          warn "$name: could not read a workflow to route a finding"
          failed=1
          continue
        fi ;;
    esac
    owner=$(route_owner "$ORG" "$name" "$path" "$text")
    if ! jq -e --arg owner "$owner" 'select(.name == $owner and .archived == false)' "$repos" >/dev/null; then
      owner="$name"
    fi
    sev=$(normalize_severity "$(jq -r '.severity' <<< "$row")")
    jq -c --arg scanned "$name" --arg owner "$owner" --arg sev "$sev" \
      '{fingerprint, finding_id, state, severity: $sev, scanned_repo: $scanned, owner_repo: $owner}' \
      <<< "$row" >> "$tmp"
  done < "$parsed"
  jq -s 'sort_by(.owner_repo, .fingerprint)' "$tmp" > "$FINDINGS_FILE"
  rm -f "$tmp"
  return "$failed"
}

# ---------------------------------------------------------------------------
# Issue management
# ---------------------------------------------------------------------------

# Public text. Takes only allow-listed fields, so it cannot leak finding detail.
# args: <fingerprint> <finding id> <severity> <scanned repo> <owner repo>
render_body() {
  local fp="$1" id="$2" sev="$3" scanned="$4" owner="$5" route=""
  if [[ "$scanned" != "$owner" ]]; then
    route="
Found by scanning \`${ORG}/${scanned}\`. Filed here because that repo's workflow is a stub calling this repo's reusable workflow; fix it here, not in the caller."
  fi
  cat <<BODY
## CodeRabbit Deep Scan finding

Severity **${sev}**, reported by CodeRabbit's LLM scan and **not yet confirmed by a person**. Generated by the org [CodeRabbit Audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/coderabbit-audit.yml).
${route}

| Field | Value |
|---|---|
| Finding ID | \`${id}\` |
| Fingerprint | \`${fp}\` |

The location and explanation are only in CodeRabbit under **Security > Findings** for \`${ORG}/${scanned}\`. This repo is public, so keep them out of this issue, its comments, and any pull request or commit message that fixes it.

### Priority
Labeled \`$(severity_priority_label "$sev")\` from the finding's severity (\`${sev}\`).

### Acceptance
- [ ] A person confirms the finding against current code in CodeRabbit, then removes \`${VERIFY_LABEL}\`
- [ ] If real: fixed, so the next Deep Scan reports it as fixed. Add \`dev-lead\` only after confirming it
- [ ] If false: use **Dismiss finding** in CodeRabbit. Closing only this issue files it again next run

---
*Idempotent issue, updated by each audit run; closed automatically when CodeRabbit reports the finding as fixed or dismissed.*

$(issue_marker "$fp")
BODY
}

# args: <finding json> <existing issue "repo number" or "">
reconcile_open() {
  local finding="$1" existing="$2"
  local fp id sev scanned owner title prio body min_rank
  fp=$(jq -r '.fingerprint' <<< "$finding")
  id=$(jq -r '.finding_id' <<< "$finding")
  sev=$(jq -r '.severity' <<< "$finding")
  scanned=$(jq -r '.scanned_repo' <<< "$finding")
  owner=$(jq -r '.owner_repo' <<< "$finding")
  title=$(issue_title "$fp")
  prio=$(severity_priority_label "$sev")

  if [[ -z "$existing" ]]; then
    min_rank=$(severity_rank "$MIN_SEVERITY")
    if [[ "$(severity_rank "$sev")" -lt "$min_rank" ]]; then
      BELOW_THRESHOLD=$((BELOW_THRESHOLD + 1))
      return 0
    fi
  fi
  if [[ "$DRY_RUN" = "true" ]]; then
    info "[dry-run] ${existing:-create in $owner} :: $title ($sev)"
    return 0
  fi

  if [[ -n "$existing" ]]; then
    local repo number other
    read -r repo number <<< "$existing"
    body=$(render_body "$fp" "$id" "$sev" "$scanned" "$repo")
    # Only the body and priority change: needs-verification and dev-lead are a
    # person's decisions, so a re-run never restores or adds them.
    if ! gh issue edit "$number" --repo "$ORG/$repo" --body "$body" --add-label "$prio" >/dev/null; then
      warn "$repo: could not update #$number"
      return 1
    fi
    for other in priority:blocker priority:critical priority:major priority:minor; do
      [[ "$other" != "$prio" ]] && gh issue edit "$number" --repo "$ORG/$repo" \
        --remove-label "$other" >/dev/null 2>&1 || true
    done
    ISSUES_EXISTING=$((ISSUES_EXISTING + 1))
    info "Updated #$number in $repo :: $title"
    return 0
  fi

  ensure_labels "$owner"
  body=$(render_body "$fp" "$id" "$sev" "$scanned" "$owner")
  local url
  if ! url=$(gh issue create --repo "$ORG/$owner" --title "$title" \
      --label "$CODERABBIT_AUDIT_LABEL,$VERIFY_LABEL,security,$prio" --body "$body"); then
    warn "$owner: could not create an issue :: $title"
    return 1
  fi
  ISSUES_ADDED=$((ISSUES_ADDED + 1))
  info "Created $url"
}

# args: <state> <existing issue "repo number">
reconcile_closed() {
  local state="$1" existing="$2" repo number
  read -r repo number <<< "$existing"
  if [[ "$DRY_RUN" = "true" ]]; then
    info "[dry-run] close #$number in $repo ($state)"
    return 0
  fi
  if ! gh issue close "$number" --repo "$ORG/$repo" \
      --comment "CodeRabbit reports this finding as ${state} as of $(date -u +%Y-%m-%d). Closing automatically." >/dev/null; then
    warn "$repo: could not close #$number"
    return 1
  fi
  ISSUES_REMOVED=$((ISSUES_REMOVED + 1))
  info "Closed #$number in $repo ($state)"
}

# args: <issue index ndjson>
reconcile_all() {
  local index="$1" finding fp state existing failed=0
  while IFS= read -r finding; do
    fp=$(jq -r '.fingerprint' <<< "$finding")
    state=$(jq -r '.state' <<< "$finding")
    existing=$(jq -r --arg fp "$fp" 'select(.fingerprint == $fp) | "\(.repo) \(.number)"' "$index" | head -1)
    if [[ "$state" = "open" ]]; then
      reconcile_open "$finding" "$existing" || failed=1
    elif [[ -n "$existing" ]]; then
      reconcile_closed "$state" "$existing" || failed=1
    fi
  done < <(jq -c '.[]' "$FINDINGS_FILE")

  # Absent from the export: left open and counted. A partial scan omits findings
  # it never reached. A sustained count here would mean fingerprints are not
  # stable across scans, so it is surfaced in the summary.
  if [[ -z "$TARGET_REPO" ]]; then
    NOT_IN_EXPORT=$(jq -r '.fingerprint' "$index" | sort -u \
      | grep -cvxFf <(jq -r '.[].fingerprint' "$FINDINGS_FILE"; echo "-") || true)
  fi
  return "$failed"
}

# ---------------------------------------------------------------------------
# Summary (public: counts only)
# ---------------------------------------------------------------------------
generate_summary() {
  local total=0 open=0
  if [[ -f "$FINDINGS_FILE" ]]; then
    total=$(jq 'length' "$FINDINGS_FILE")
    open=$(jq '[.[] | select(.state == "open")] | length' "$FINDINGS_FILE")
  fi
  {
    echo "# CodeRabbit Audit — $(date -u +%Y-%m-%d)"
    echo ""
    echo "**Org:** \`${ORG}\` · **Findings read:** ${total} · **Open:** ${open} · **Minimum severity to file:** ${MIN_SEVERITY}"
    if [[ -n "$RUN_ERROR" ]]; then
      echo ""
      echo "> [!WARNING]"
      echo "> ${RUN_ERROR} Issues were left untouched. Check the workflow logs."
    fi
    echo ""
    [[ "$DRY_RUN" = "true" ]] && { echo "Dry run: no issues written."; echo ""; }
    echo "## Open findings by severity"
    echo "| Severity | Findings |"
    echo "|---|---:|"
    if [[ -f "$FINDINGS_FILE" ]]; then
      jq -r '[.[] | select(.state == "open")] | group_by(.severity) | .[] | "| \(.[0].severity) | \(length) |"' "$FINDINGS_FILE"
    fi
    echo ""
    echo "## Issue actions"
    echo "| Action | Count |"
    echo "|---|---:|"
    echo "| Added | $ISSUES_ADDED |"
    echo "| Updated | $ISSUES_EXISTING |"
    echo "| Closed (fixed or dismissed in CodeRabbit) | $ISSUES_REMOVED |"
    echo "| Not filed (below minimum severity) | $BELOW_THRESHOLD |"
    echo "| Left open (finding absent from this export) | $NOT_IN_EXPORT |"
    echo "| Skipped (repo archived or outside this org) | $UNMAPPED |"
    echo ""
    echo "---"
    echo "*Generated by the CodeRabbit Audit workflow. Finding detail is only in CodeRabbit.*"
  } > "$SUMMARY_FILE"
}

# ---------------------------------------------------------------------------
fail_run() {
  RUN_ERROR="$1"
  generate_summary
  warn "$1"
  return 1
}

main() {
  mkdir -p "$REPORT_DIR"
  info "CodeRabbit audit — org=$ORG dry_run=$DRY_RUN target=${TARGET_REPO:-all} min_severity=$MIN_SEVERITY"
  if [[ -z "${CODERABBIT_API_KEY:-}" ]]; then
    fail_run "CODERABBIT_API_KEY is not set."
    return 1
  fi

  # Raw SARIF and routing paths stay here, outside REPORT_DIR.
  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now: $work is local to main
  trap "rm -rf '$work'" EXIT

  local repos="$work/repos.ndjson"
  list_org_repos > "$repos" || { fail_run "Could not list repos in $ORG."; return 1; }
  [[ -s "$repos" ]] || { fail_run "The token lists no repos in $ORG."; return 1; }

  local target_id=""
  if [[ -n "$TARGET_REPO" ]]; then
    target_id=$(jq -r --arg n "${TARGET_REPO#"$ORG/"}" 'select(.name == $n) | .id' "$repos")
    [[ -n "$target_id" ]] || { fail_run "TARGET_REPO is not a repo in $ORG."; return 1; }
  fi

  fetch_sarif "$work/export.sarif" "$target_id" || { fail_run "The CodeRabbit export could not be read."; return 1; }
  parse_sarif "$work/export.sarif" "$work/parsed.ndjson" || { fail_run "The CodeRabbit export was not in the expected format."; return 1; }
  rm -f "$work/export.sarif"

  resolve_findings "$work/parsed.ndjson" "$repos" || { fail_run "A workflow needed for routing could not be read."; return 1; }

  local names
  names=$(jq -r 'select(.archived == false) | .name' "$repos")
  build_issue_index "$names" "$work/index.ndjson" || { fail_run "Audit issues could not be listed, so duplicates could not be ruled out."; return 1; }

  local issues_failed=0
  reconcile_all "$work/index.ndjson" || issues_failed=1

  jq -n --argjson added "$ISSUES_ADDED" --argjson existing "$ISSUES_EXISTING" --argjson removed "$ISSUES_REMOVED" \
        '{added:$added,existing:$existing,removed:$removed}' > "$COUNTS_FILE"
  generate_summary
  info "Done. findings=$(jq length "$FINDINGS_FILE") added=$ISSUES_ADDED updated=$ISSUES_EXISTING closed=$ISSUES_REMOVED"

  if [[ "$issues_failed" = "1" ]]; then
    warn "one or more audit issues could not be created, updated or closed — see the log"
    return 1
  fi
}

# Guard: only run when executed directly (sourcing defines functions for bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
