#!/usr/bin/env bash
# Daily org status data collector — runs in GitHub Actions, outputs a markdown report to stdout.
set -euo pipefail

TODAY=$(date -u +%Y-%m-%d)
if [[ "$(uname)" == "Darwin" ]]; then
  SINCE=$(date -u -v-7d +%Y-%m-%d)
else
  SINCE=$(date -u -d '7 days ago' +%Y-%m-%d)
fi
DATA_DIR=$(mktemp -d)
trap 'rm -rf "$DATA_DIR"' EXIT

# ── Repo Discovery ────────────────────────────────────────────────────────────
echo "::group::Discovering repos" >&2
ORG_REPOS=$(gh repo list combsmith --json name --limit 1000 | jq -r '.[].name' | sort)
PERSONAL_REPOS=$(gh repo list don-petry --json name --limit 1000 | jq -r '.[].name' | sort)
echo "combsmith: $(echo "$ORG_REPOS" | wc -l | tr -d ' ') repos  |  don-petry: $(echo "$PERSONAL_REPOS" | wc -l | tr -d ' ') repos" >&2
echo "::endgroup::" >&2

# ── PR Collection + Classification ───────────────────────────────────────────
collect_classify_prs() {
  local owner=$1 repo=$2
  local cursor="" all_nodes_ndjson=""
  # cursor="" = first page (pass JSON null); cursor=VALUE = subsequent pages (pass as string)

  while true; do
    local result
    local -a cursor_arg
    if [ -z "$cursor" ]; then
      cursor_arg=(-F cursor=null)   # -F = JSON-typed: passes null, not the string "null"
    else
      cursor_arg=(-f "cursor=$cursor")
    fi

    result=$(gh api graphql \
      "${cursor_arg[@]}" \
      -f query='query($owner:String!,$repo:String!,$cursor:String){
        repository(owner:$owner,name:$repo){
          pullRequests(states:OPEN,first:100,after:$cursor){
            pageInfo{hasNextPage endCursor}
            nodes{
              number title createdAt isDraft
              headRefName baseRefName
              labels(first:20){nodes{name}}
              reviewDecision
              statusCheckRollup{state}
              reviews(last:20){nodes{state}}
              closingIssuesReferences(first:10){nodes{number}}
            }
          }
        }
      }' \
      -f owner="$owner" -f repo="$repo" 2>/dev/null) \
      || result='{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}'

    local nodes has_next end_cursor
    nodes=$(jq '.data.repository.pullRequests.nodes // []' <<< "$result")
    has_next=$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage // false' <<< "$result")
    end_cursor=$(jq -r '.data.repository.pullRequests.pageInfo.endCursor // ""' <<< "$result")

    all_nodes_ndjson+=$(jq -c '.[]' <<< "$nodes")
    all_nodes_ndjson+=$'\n'
    [ "$has_next" = "true" ] && [ -n "$end_cursor" ] || break
    cursor="$end_cursor"
  done

  jq -cs --arg owner "$owner" --arg repo "$repo" '
    map({
      repo:   ($owner + "/" + $repo),
      number: .number,
      title:  .title,
      opened: (.createdAt | split("T")[0]),
      url:    ("https://github.com/" + $owner + "/" + $repo + "/pull/" + (.number|tostring)),
      headRefName: .headRefName,
      baseRefName: .baseRefName,
      labels: [.labels.nodes[].name],
      isDraft: .isDraft,
      ci:     (.statusCheckRollup.state // null),
      review: (.reviewDecision // null),
      approvals: ([.reviews.nodes[] | select(.state=="APPROVED")] | length),
      needsHumanReview: ([.labels.nodes[].name] | any(. == "needs-human-review")),
      isDepBump: (.title | test("^chore\\(deps")),
      closingIssues: [.closingIssuesReferences.nodes[].number],
      category: (
        if   .isDraft then "Draft"
        elif (.statusCheckRollup.state == "FAILURE" or .statusCheckRollup.state == "ERROR") then "CI Failing"
        elif (.statusCheckRollup.state == "PENDING" or .statusCheckRollup.state == "EXPECTED") then "CI Pending"
        elif .reviewDecision == "CHANGES_REQUESTED" then "Changes Requested"
        elif .reviewDecision == "APPROVED" then "Approved"
        elif .reviewDecision == "REVIEW_REQUIRED" then "Awaiting Review"
        else "No CI / No Policy"
        end
      )
    })' <<< "$all_nodes_ndjson"
}

echo "::group::Collecting PR data" >&2
# Accumulate as NDJSON then slurp — avoids passing a growing $ALL_PRS as a
# shell argument to jq, which hits ARG_MAX once the org accumulates ~200+ PRs.
ALL_PR_NDJSON=""
for repo in $ORG_REPOS; do
  prs=$(collect_classify_prs "combsmith" "$repo")
  count=$(jq 'length' <<< "$prs")
  [ "$count" -gt 0 ] && echo "  combsmith/$repo: $count open PRs" >&2
  if [ "$count" -gt 0 ]; then
    ALL_PR_NDJSON+=$(jq -c '.[]' <<< "$prs")
    ALL_PR_NDJSON+=$'\n'
  fi
done
for repo in $PERSONAL_REPOS; do
  prs=$(collect_classify_prs "don-petry" "$repo")
  count=$(jq 'length' <<< "$prs")
  [ "$count" -gt 0 ] && echo "  don-petry/$repo: $count open PRs" >&2
  if [ "$count" -gt 0 ]; then
    ALL_PR_NDJSON+=$(jq -c '.[]' <<< "$prs")
    ALL_PR_NDJSON+=$'\n'
  fi
done
ALL_PRS=$(jq -cs '.' <<< "$ALL_PR_NDJSON")
echo "Total open PRs: $(echo "$ALL_PRS" | jq 'length')" >&2
echo "::endgroup::" >&2

# ── Behind-Base Detection ─────────────────────────────────────────────────────
# For each PR, compute behind_by via the REST compare API. PRs with behind_by > 0
# need to be rebased/merged with their base branch before they can land.
# (GraphQL has no equivalent field; mergeable only reports CONFLICTING.)
echo "::group::Computing behind_by per PR" >&2
# Accumulate one augmented PR per line of NDJSON, then slurp into a single
# array at the end — avoids O(n²) reparse of a growing array each iteration.
AUGMENTED_NDJSON=""
while IFS= read -r pr; do
  [ -z "$pr" ] && continue
  pr_repo=$(echo "$pr" | jq -r '.repo')
  pr_head=$(echo "$pr" | jq -r '.headRefName')
  pr_base=$(echo "$pr" | jq -r '.baseRefName')
  if compare_response=$(gh api "repos/${pr_repo}/compare/${pr_base}...${pr_head}" --jq '.behind_by' 2>&1); then
    behind="$compare_response"
  else
    echo "  WARN: compare ${pr_repo} ${pr_base}...${pr_head} failed — treating as up to date: $compare_response" >&2
    behind=0
  fi
  [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
  AUGMENTED_NDJSON+=$(echo "$pr" | jq -c --argjson b "$behind" '. + {behindBy: $b, needsRebase: ($b > 0)}')
  AUGMENTED_NDJSON+=$'\n'
done <<< "$(echo "$ALL_PRS" | jq -c '.[]')"
ALL_PRS=$(echo "$AUGMENTED_NDJSON" | jq -cs '.')
NEEDS_REBASE_COUNT=$(echo "$ALL_PRS" | jq '[.[] | select(.needsRebase)] | length')
echo "PRs needing rebase: $NEEDS_REBASE_COUNT" >&2
echo "::endgroup::" >&2

# Pre-aggregate PR counts by category per repo (keeps prompt size manageable)
PR_BY_REPO=$(echo "$ALL_PRS" | jq '
  sort_by(.repo) | group_by(.repo) | map({
    repo: .[0].repo,
    total: length,
    draft:             ([.[] | select(.category=="Draft")] | length),
    ci_failing:        ([.[] | select(.category=="CI Failing")] | length),
    ci_pending:        ([.[] | select(.category=="CI Pending")] | length),
    changes_requested: ([.[] | select(.category=="Changes Requested")] | length),
    approved:          ([.[] | select(.category=="Approved")] | length),
    awaiting_review:   ([.[] | select(.category=="Awaiting Review")] | length),
    no_ci_policy:      ([.[] | select(.category=="No CI / No Policy")] | length),
    dep_bumps:         ([.[] | select(.isDepBump)] | length),
    needs_rebase:      ([.[] | select(.needsRebase)] | length)
  }) | sort_by(-.total)')

NEEDS_REVIEW_PRS=$(echo "$ALL_PRS" | jq '[.[] | select(.needsHumanReview)]')

# Map of "owner/repo#issue_number" -> [{pr_number, pr_url}] for issues that have a linked PR
ISSUE_PR_MAP=$(echo "$ALL_PRS" | jq '
  [.[] | . as $pr | ($pr.closingIssues // [])[] |
    {key: ($pr.repo + "#" + (. | tostring)), value: {number: $pr.number, url: $pr.url}}
  ] | sort_by(.key) | group_by(.key) | map({
    key:   .[0].key,
    value: [.[] | .value]
  }) | from_entries')

# ── Merge Activity ────────────────────────────────────────────────────────────
echo "::group::Collecting merge activity" >&2
ORG_MERGES=$(gh search prs --owner=combsmith --merged --merged-at=">=$SINCE" \
  --json number,repository,closedAt --limit 1000 2>/dev/null || echo '[]')
PERSONAL_MERGES=$(gh search prs --owner=don-petry --merged --merged-at=">=$SINCE" \
  --json number,repository,closedAt --limit 1000 2>/dev/null || echo '[]')

# Write merges to a temp file so subsequent jq calls read from a file descriptor
# rather than shell arguments — avoids the same ARG_MAX risk at high merge volumes.
printf '{"org":%s,"personal":%s}\n' "$ORG_MERGES" "$PERSONAL_MERGES" > "$DATA_DIR/merges.json"

MERGE_DAILY=$(jq --arg since "$SINCE" --arg today "$TODAY" '
  .org as $org | .personal as $personal |
  # Build 8-day date list (since through today inclusive)
  def dates: [range(8) | ($since | strptime("%Y-%m-%d") | mktime) + (. * 86400) | strftime("%Y-%m-%d")];
  # Capture $date before entering the generator so . refers to the right scope
  dates | map(. as $date | {
    date: $date,
    org:      ([$org[]      | select(.closedAt[:10] == $date)] | length),
    personal: ([$personal[] | select(.closedAt[:10] == $date)] | length)
  })' "$DATA_DIR/merges.json")

# Per-repo per-day merge counts (for the enhanced merge activity table)
MERGE_BY_REPO_DAY=$(jq --arg since "$SINCE" '
  .org as $org | .personal as $personal |
  def dates: [range(8) | ($since | strptime("%Y-%m-%d") | mktime) + (. * 86400) | strftime("%Y-%m-%d")];
  (($org      | map({repo: ("combsmith/" + .repository.name), date: .closedAt[:10]})) +
   ($personal | map({repo: ("don-petry/"      + .repository.name), date: .closedAt[:10]}))) |
  sort_by(.repo) | group_by(.repo) | map(
    . as $items |
    {
      repo:    $items[0].repo,
      total:   ($items | length),
      by_date: (dates | map(. as $d | {key: $d, value: ([$items[] | select(.date == $d)] | length)}) | from_entries)
    }
  ) | sort_by(-.total)' "$DATA_DIR/merges.json")
echo "::endgroup::" >&2

# ── Issues ────────────────────────────────────────────────────────────────────
echo "::group::Collecting issues" >&2
ISSUES_NDJSON=""
for repo in $ORG_REPOS; do
  issues=$(gh issue list --repo "combsmith/$repo" --state open \
    --json number,title,createdAt,labels,url --limit 1000 2>/dev/null || echo '[]')
  count=$(jq 'length' <<< "$issues")
  if [ "$count" -gt 0 ]; then
    echo "  combsmith/$repo: $count open issues" >&2
    ISSUES_NDJSON+=$(jq -c --arg repo "combsmith/$repo" '{repo: $repo, count: length, issues: .}' <<< "$issues")
    ISSUES_NDJSON+=$'\n'
  fi
done
for repo in $PERSONAL_REPOS; do
  issues=$(gh issue list --repo "don-petry/$repo" --state open \
    --json number,title,createdAt,labels,url --limit 1000 2>/dev/null || echo '[]')
  count=$(jq 'length' <<< "$issues")
  if [ "$count" -gt 0 ]; then
    echo "  don-petry/$repo: $count open issues" >&2
    ISSUES_NDJSON+=$(jq -c --arg repo "don-petry/$repo" '{repo: $repo, count: length, issues: .}' <<< "$issues")
    ISSUES_NDJSON+=$'\n'
  fi
done
ISSUES_BY_REPO=$(jq -cs '.' <<< "$ISSUES_NDJSON")
echo "::endgroup::" >&2

# ── Discussions ───────────────────────────────────────────────────────────────
echo "::group::Collecting discussions" >&2
DISCUSSIONS=$(gh api graphql -f query='
{
  organization(login:"combsmith"){
    repositories(first:100){
      nodes{
        name hasDiscussionsEnabled
        discussions(first:50,states:OPEN){
          totalCount
          nodes{
            number title createdAt
            comments{totalCount}
            labels(first:20){nodes{name}}
          }
        }
      }
    }
  }
}' 2>/dev/null | jq '[
  .data.organization.repositories.nodes[]
  | select(.hasDiscussionsEnabled and .discussions.totalCount > 0)
  | . as $r
  | {
      repo: ("combsmith/" + .name),
      discussions: [
        .discussions.nodes[] | . + {
          url: ("https://github.com/combsmith/" + $r.name + "/discussions/" + (.number|tostring))
        }
      ]
    }
]') || DISCUSSIONS='[]'
echo "::endgroup::" >&2

# ── Build Prompt ──────────────────────────────────────────────────────────────
# Limit issues per repo to keep prompt size manageable and ensure Claude has
# enough output budget to generate all sections (especially the PR tables first).
ISSUE_LIMIT=25
ISSUES_BY_REPO_TRIMMED=$(echo "$ISSUES_BY_REPO" | jq --argjson limit "$ISSUE_LIMIT" '
  map({
    repo:      .repo,
    count:     .count,
    truncated: (.count > $limit),
    issues:    .issues[:$limit]
  })')

cat > "$DATA_DIR/prompt.txt" << PROMPT
Generate a daily GitHub org status report for $TODAY.

Use ONLY the data below. Output ONLY the markdown report — no preamble, no commentary.

CRITICAL: You MUST output ALL sections listed in REPORT FORMAT, in order. Do NOT skip or abbreviate any section. The PR summary table MUST appear first.

---

## DATA

### PR Counts by Repo (pre-classified)
$(echo "$PR_BY_REPO" | jq -c '.')

### PRs Needing Human Review (full detail, includes url field)
$(echo "$NEEDS_REVIEW_PRS" | jq -c '.')

### Issue → Linked PR Map (key: "owner/repo#issue_number", value: [{number, url}])
$(echo "$ISSUE_PR_MAP" | jq -c '.')

### Merge Activity — Daily Counts (last 8 days, $SINCE to $TODAY)
$(echo "$MERGE_DAILY" | jq -c '.')

### Merge Activity — Per-Repo Per-Day (repo, total, by_date map keyed by YYYY-MM-DD)
$(echo "$MERGE_BY_REPO_DAY" | jq -c '.')

### Open Issues by Repo (each issue has url field; truncated:true means more exist beyond the 25 shown)
$(echo "$ISSUES_BY_REPO_TRIMMED" | jq -c '.')

### Open Discussions (each discussion has url field)
$(echo "$DISCUSSIONS" | jq -c '.')

---

## REPORT FORMAT

Begin the report with this exact line (replace nothing):
@org-leads

Then produce these sections in order. IMPORTANT: output each \`##\` section header before its table content — do NOT skip any section header or table header row.

### \`## Open PRs — Why They're Unmerged (N total)\`
(Replace N with the actual total count.)
Org-wide blocker summary table (sum all repos). You MUST include the header row and separator row:
| Category | Count | % of Total |
|---|---|---|
Rows in this order: Awaiting Review, CI Failing, CI Pending, Changes Requested, Approved, Draft, No CI / No Policy, **TOTAL**

Per-repo breakdown table (omit repos with 0 total PRs). You MUST include the header row and separator row:
| Repo | Total | Awaiting Review | CI Failing | CI Pending | Changes Req | Approved | No CI/Policy | Draft | Needs Rebase |
|---|---|---|---|---|---|---|---|---|---|
- Repo name as a link to the repo: [owner/repo](https://github.com/owner/repo)
- Add ⚠ next to repo name if CI Failing > 5 or Awaiting Review > 10
- Needs Rebase column: render the \`needs_rebase\` count from the data. If the count is 0 render —. If > 0 render the number followed by 🔄 (e.g. \`3 🔄\`).

### \`## Open PRs — Needs Human Review\`
Full table for PRs with needsHumanReview == true:
| Repo | PR | Opened | CI | Approvals |
|---|---|---|---|---|
- PR cell: single markdown link combining number and title, e.g. \`[#42 — Fix the thing](url)\`
- CI: PASS (SUCCESS) / FAIL (FAILURE or ERROR) / PENDING / N/A (null)
If none: _none_

### \`## Open PRs — Automation (Dependency Bumps)\`
Counts only per repo (dep_bumps > 0):
| Repo | # Dep PRs |
|---|---|
- Repo as link: [owner/repo](https://github.com/owner/repo)
If none: _none_

### \`## Open Issues (N total)\`
Render as a per-repo subsection list (NOT a single flat table). For each repo with issues, in the order provided:

\`### [owner/repo](https://github.com/owner/repo) (N issues)\`
- If truncated:true, replace the suffix with " (showing $ISSUE_LIMIT of N issues)".

Then a small table (Repo column omitted — it's in the heading):
| Issue | Opened | Labels | Linked PR |
|---|---|---|---|
- Issue cell: single markdown link combining number and title, e.g. \`[#123 — Compliance: foo](url)\`
- Opened = createdAt date only (YYYY-MM-DD)
- Linked PR: look up "owner/repo#N" in the Issue→Linked PR Map; if found render as [#M](pr_url); if multiple, comma-separate; if none render —

### \`## PR Merge Activity — Last 8 Days\`
Per-repo-per-day table using the Merge Activity — Per-Repo Per-Day data (omit repos with 0 total):
| Repo | Mon-DD | Mon-DD | … | Total |
- One column per date in chronological order (all 8 dates, even if 0 across all repos)
- Date headers: short format Mon-DD (e.g. Apr-26)
- Repo as link: [owner/repo](https://github.com/owner/repo)
- Last column is Total (bold the number)
- Add a **TOTAL** row summing each date column and grand total
Daily org-level summary table (include zero rows):
| Date | combsmith | don-petry | Grand Total |
Grand total and trend sentence. Trend: Increasing if avg(last 3 days) > avg(first 3 days), Decreasing if opposite, Flat otherwise.

### \`## Open Discussions\`
| Repo | Discussion | Opened | Replies |
|---|---|---|---|
- Discussion cell: single markdown link combining number and title, e.g. \`[#7 — Feature idea](url)\`
If none: _none_

---

OUTPUT CONTRACT
- Dates: YYYY-MM-DD
- Section headers include total counts: \`## Open Issues (47 total)\`
- Empty sections show _none_, never omit them
- Every item with a url must be rendered as a markdown hyperlink
PROMPT

# ── Generate Report ───────────────────────────────────────────────────────────
# --disallowedTools: block all action tools so Claude cannot act on untrusted PR/issue content
# Pipe prompt via stdin rather than a shell argument to avoid ARG_MAX (~1MB) with large orgs
echo "Generating report with Claude..." >&2
claude -p \
  --disallowedTools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
  < "$DATA_DIR/prompt.txt"
