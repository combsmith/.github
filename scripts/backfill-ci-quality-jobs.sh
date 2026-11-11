#!/usr/bin/env bash
set -euo pipefail
# backfill-ci-quality-jobs.sh — fleet backfill of the `secret-scan` and `coverage`
# CI jobs, and the gate for requiring them in code-quality (combsmith/.github#581).
#
# WHY THIS EXISTS. Once `coverage` and `Secret scan (gitleaks)` are added to
# standards/rulesets/code-quality.json, every repo that apply-rulesets.sh targets
# must report both checks, or every merge there is blocked for good. The template
# ci.yml ships both jobs (#578), but existing fleet repos do not have them yet.
# The order is (#581):
#   1. backfill  — add the jobs to every repo's ci.yml, one standards-sync PR per repo
#   2. --verify  — confirm every repo now reports both checks successfully
#   3. only then — add the two contexts to code-quality.json and run apply-rulesets.sh --all
#
# WHY NOT deploy-standard-workflows.sh. ci.yml is customized per stack and is left
# out of DEPLOYABLE_WORKFLOWS. Copying the template over it would delete a repo's
# real build and test jobs. This script ADDS the template's two job blocks,
# unchanged, to the end of the repo's existing `jobs:` mapping and leaves the rest
# of the file alone. The blocks come from standards/workflows/ci.yml (the source of
# truth) and are never generated, so the backfilled jobs match the template exactly.
# When it adds the secret-scan job and the repo has no .gitleaks.toml, it also seeds
# one from standards/gitleaks.toml, because the job runs with `--config .gitleaks.toml`.
#
# REPO SET. --all uses apply-rulesets.sh's classify_fleet_repos, so the repos this
# backfills and verifies are exactly the repos the ruleset is applied to (archived
# repos, GHSA forks and FLEET_EXCLUDE are skipped there too).
#
# Usage:
#   backfill-ci-quality-jobs.sh --repo <owner/repo|name> [--dry-run]
#   backfill-ci-quality-jobs.sh --all [--dry-run]
#   backfill-ci-quality-jobs.sh --verify --repo <owner/repo|name>
#   backfill-ci-quality-jobs.sh --verify --all
#
# Backfill outcomes (one line per repo):
#   OK        both jobs already present, nothing to do
#   PLAN      (dry-run) the jobs/files that would be added
#   OPENED    a standards-sync PR was opened
#   SKIP_PR_OPEN  the repo already has an open standards-sync PR (re-run after it merges)
#   NO_CI     no .github/workflows/ci.yml, so it needs a manual setup (see ci-standards.md)
#   CONFLICT  a job uses the id `secret-scan`/`coverage` but its check name differs,
#             so it needs a manual fix (adding a second job with that id is invalid YAML)
#   FAILED    an API or injection error occurred
#
# Verify outcomes: PASS / MISSING <contexts>. Verify reads the check runs on the
# default branch tip, falling back to the head of the most recent PR for repos
# whose CI runs only on pull_request. It exits non-zero if any repo is not PASS.
# Do not do step 3 until `--verify --all` exits 0.
#
# Env:
#   GH_TOKEN   repo scope (branch + PR creation) for backfill; read access for --verify
#   ORG        org for --all and bare repo names (default: combsmith)
#   DRY_RUN    "true" → same as --dry-run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORG="${ORG:-combsmith}"
DRY_RUN="${DRY_RUN:-false}"

# classify_fleet_repos + resolve_repo (and FLEET_EXCLUDE): the fleet that the
# code-quality ruleset is applied to. Sourcing does not run apply-rulesets' main.
# shellcheck source=scripts/apply-rulesets.sh
. "${SCRIPT_DIR}/apply-rulesets.sh"
# shellcheck source=scripts/lib/standards-deploy.sh
. "${SCRIPT_DIR}/lib/standards-deploy.sh"

CBF_TEMPLATE_CI="${CBF_TEMPLATE_CI:-${REPO_ROOT}/standards/workflows/ci.yml}"
CBF_TEMPLATE_GITLEAKS="${CBF_TEMPLATE_GITLEAKS:-${REPO_ROOT}/standards/gitleaks.toml}"
CBF_BRANCH="standards-sync/ci-quality-jobs"
CBF_LABEL="standards-sync"

# The jobs to backfill: "<job-id>|<check name>". The check name is the required
# context that code-quality.json will carry (#581 step 3).
readonly CBF_JOBS=(
  "secret-scan|Secret scan (gitleaks)"
  "coverage|coverage"
)

# cbf_job_status <ci_file> <job_id> <check_name> — echo present | missing | conflict.
#   present   some job reports <check_name> (its `name:`, or its id when it has no name;
#             a reusable-workflow caller job (`uses:`) never does)
#   conflict  no job reports <check_name>, but <job_id> is taken by a job that
#             reports something else, so the template block cannot be added
#   missing   neither, so the template block can be added
cbf_job_status() {
  local file="$1" id="$2" check="$3"
  ID="$id" CHECK="$check" yq -r '
    (.jobs // {}) | to_entries |
    (map(select((.value.uses == null) and ((.value.name // .key) == strenv(CHECK)))) | length) as $hit |
    (map(select(.key == strenv(ID))) | length) as $taken |
    if $hit > 0 then "present" elif $taken > 0 then "conflict" else "missing" end
  ' "$file"
}

# cbf_reports_check <workflow_file> <check_name> — true if any job in the file
# reports <check_name>. A file that does not parse counts as not reporting it.
# A job that calls a reusable workflow (`uses:`) is reported by GitHub as
# "<caller> / <called job>", so it never reports a bare <check_name>.
cbf_reports_check() {
  (( $(CHECK="$2" yq -r '[(.jobs // {}) | to_entries | .[] | select((.value.uses == null) and ((.value.name // .key) == strenv(CHECK)))] | length' "$1" 2>/dev/null) > 0 )) 2>/dev/null
}

# cbf_extract_job <template_ci> <job_id> — print the job's block from the template
# exactly as written, including the comment lines directly above it, without
# trailing blank lines. The template indents job keys by 2 spaces. Returns 1 if
# the job is not found.
cbf_extract_job() {
  awk -v id="$2" '
    /^jobs:[[:space:]]*(#.*)?$/ { injobs = 1; next }
    !injobs { next }
    /^[^[:space:]#]/ { injobs = 0; next }          # next top-level key ends jobs:
    /^  #/ { if (!ncom) comstart = NR; com[++ncom] = $0; next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      key = $0; sub(/^  /, "", key); sub(/:.*/, "", key)
      if (grab) { grab = 0 }
      if (key == id) { grab = 1; for (i = 1; i <= ncom; i++) out[++n] = com[i] }
      ncom = 0
      if (grab) out[++n] = $0
      next
    }
    /^[[:space:]]*$/ { if (grab) out[++n] = $0; ncom = 0; next }
    { if (grab) { for (i = 1; i <= ncom; i++) out[++n] = com[i]; out[++n] = $0 }; ncom = 0 }
    END {
      while (n > 0 && out[n] ~ /^[[:space:]]*$/) n--
      if (n == 0) exit 1
      for (i = 1; i <= n; i++) print out[i]
    }
  ' "$1"
}

# cbf_inject_block <ci_file> <block_file> — write ci_file with block_file added at
# the end of its `jobs:` mapping to stdout. Lines after the mapping (such as a
# later top-level key) are kept unchanged. The block's 2-space base indent is
# swapped for the indent of the repo's own job keys. Returns 1 if there is no
# top-level `jobs:`.
cbf_inject_block() {
  awk -v blockfile="$2" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (line[i] ~ /^jobs:[[:space:]]*(#.*)?$/) { j = i; break }
      if (!j) exit 1
      indent = "  "; last = j
      for (i = j + 1; i <= NR; i++) {
        if (line[i] ~ /^[[:space:]]*$/ || line[i] ~ /^#/) continue
        if (line[i] ~ /^[^[:space:]]/) break             # next top-level key
        if (!found) { found = 1; match(line[i], /^[[:space:]]+/); indent = substr(line[i], 1, RLENGTH) }
        last = i
      }
      for (i = 1; i <= last; i++) print line[i]
      print ""
      while ((getline b < blockfile) > 0) {
        if (b ~ /^[[:space:]]*$/) { print ""; continue }
        sub(/^  /, "", b); print indent b
      }
      for (i = last + 1; i <= NR; i++) print line[i]
    }
  ' "$1"
}

# cbf_backfill_file <ci_file> <out_file> [<other_workflow>...] — write ci_file
# with every missing job from CBF_JOBS added to out_file, and print the ids it
# added (space-separated, possibly empty). A check that one of the repo's OTHER
# workflow files already reports (e.g. a coverage.yml) is not missing. Adding it
# again to ci.yml would create a second check run with the same name. Returns 2 on a conflict (the conflicting ids go to stderr) and
# 1 on an error. The result must parse as YAML with every job present, or the
# function fails rather than produce a broken workflow.
cbf_backfill_file() {
  local src="$1" out="$2" entry id check status added=() conflicts=() block tmp other elsewhere
  shift 2
  yq -e '.jobs' "$src" >/dev/null 2>&1 || { echo "no top-level jobs: mapping in ci.yml" >&2; return 1; }
  cp "$src" "$out"
  for entry in "${CBF_JOBS[@]}"; do
    id="${entry%%|*}"; check="${entry#*|}"
    elsewhere=false
    for other in "$@"; do cbf_reports_check "$other" "$check" && { elsewhere=true; break; }; done
    [[ "$elsewhere" = true ]] && continue
    status="$(cbf_job_status "$out" "$id" "$check")" || return 1
    case "$status" in
      present) ;;
      conflict) conflicts+=("$id") ;;
      missing)
        block="$(mktemp)"; tmp="$(mktemp)"
        cbf_extract_job "$CBF_TEMPLATE_CI" "$id" > "$block" \
          || { rm -f "$block" "$tmp"; echo "job ${id} not found in ${CBF_TEMPLATE_CI}" >&2; return 1; }
        cbf_inject_block "$out" "$block" > "$tmp" || { rm -f "$block" "$tmp"; return 1; }
        mv "$tmp" "$out"; rm -f "$block"
        added+=("$id") ;;
    esac
  done
  if (( ${#conflicts[@]} > 0 )); then echo "${conflicts[*]}" >&2; return 2; fi
  # Check the result: still valid YAML, and every job now reports its check.
  yq -e '.' "$out" >/dev/null 2>&1 || { echo "injected ci.yml is not valid YAML" >&2; return 1; }
  for entry in "${CBF_JOBS[@]}"; do
    cbf_reports_check "$out" "${entry#*|}" && continue
    elsewhere=false
    for other in "$@"; do cbf_reports_check "$other" "${entry#*|}" && { elsewhere=true; break; }; done
    [[ "$elsewhere" = true ]] || { echo "job ${entry%%|*} still missing after injection" >&2; return 1; }
  done
  echo "${added[*]}"
}

# cbf_fetch <repo> <path> <out_file> — fetch a file from the default branch.
# Returns 0 if found, 4 on HTTP 404, 1 on any other error.
cbf_fetch() {
  local repo="$1" path="$2" out="$3" err rc=0
  err="$(mktemp)"
  gh api -H "Accept: application/vnd.github.raw+json" "repos/${repo}/contents/${path}" \
    >"$out" 2>"$err" && rc=0 || rc=$?
  if (( rc != 0 )); then
    if grep -q 'HTTP 404' "$err"; then rm -f "$err"; return 4; fi
    echo "$(head -c 200 "$err" | tr '\n' ' ')" >&2; rm -f "$err"; return 1
  fi
  rm -f "$err"
}

# cbf_backfill_repo <owner/repo> — print one outcome line; non-zero on FAILED.
cbf_backfill_repo() {
  local repo="$1" ci new added rc=0 err files=() seed=false outcome
  ci="$(mktemp)"; new="$(mktemp)"; err="$(mktemp)"
  cbf_fetch "$repo" ".github/workflows/ci.yml" "$ci" 2>"$err" && rc=0 || rc=$?
  if (( rc == 4 )); then
    echo "NO_CI ${repo} — no .github/workflows/ci.yml; set one up from standards/workflows/ci.yml"
    rm -f "$ci" "$new" "$err"; return 0
  elif (( rc != 0 )); then
    echo "FAILED ${repo} fetch-ci: $(cat "$err")"; rm -f "$ci" "$new" "$err"; return 1
  fi

  # The repo's other workflows: a check one of them already reports is not added to ci.yml.
  local wfdir names name others=()
  wfdir="$(mktemp -d)"
  names="$(gh api "repos/${repo}/contents/.github/workflows" \
    --jq '.[] | select(.type == "file") | .name' 2>"$err")" \
    || { echo "FAILED ${repo} list-workflows: $(head -c 200 "$err" | tr '\n' ' ')"; rm -rf "$ci" "$new" "$err" "$wfdir"; return 1; }
  while IFS= read -r name; do
    case "$name" in ci.yml|"") continue ;; *.yml|*.yaml) ;; *) continue ;; esac
    cbf_fetch "$repo" ".github/workflows/${name}" "${wfdir}/${name}" 2>"$err" \
      || { echo "FAILED ${repo} fetch-workflow ${name}: $(cat "$err")"; rm -rf "$ci" "$new" "$err" "$wfdir"; return 1; }
    others+=("${wfdir}/${name}")
  done <<< "$names"

  added="$(cbf_backfill_file "$ci" "$new" "${others[@]}" 2>"$err")" && rc=0 || rc=$?
  rm -rf "$wfdir"
  if (( rc == 2 )); then
    echo "CONFLICT ${repo} — job id(s) $(cat "$err") already used for a different check name; fix by hand"
    rm -f "$ci" "$new" "$err"; return 0
  elif (( rc != 0 )); then
    echo "FAILED ${repo} inject: $(cat "$err")"; rm -f "$ci" "$new" "$err"; return 1
  fi
  if [[ -z "$added" ]]; then
    echo "OK ${repo} — secret-scan and coverage already present"
    rm -f "$ci" "$new" "$err"; return 0
  fi
  files=(".github/workflows/ci.yml" "$new")

  # Seed .gitleaks.toml when this PR adds the secret-scan job and the repo has none.
  if [[ " ${added} " == *" secret-scan "* ]]; then
    local probe; probe="$(mktemp)"
    cbf_fetch "$repo" ".gitleaks.toml" "$probe" 2>"$err" && rc=0 || rc=$?
    rm -f "$probe"
    if (( rc == 4 )); then seed=true; files+=(".gitleaks.toml" "$CBF_TEMPLATE_GITLEAKS")
    elif (( rc != 0 )); then
      echo "FAILED ${repo} fetch-gitleaks: $(cat "$err")"; rm -f "$ci" "$new" "$err"; return 1
    fi
  fi

  if [[ "$DRY_RUN" = true ]]; then
    echo "PLAN ${repo} — add job(s): ${added}$([[ "$seed" = true ]] && echo '; seed .gitleaks.toml')"
    rm -f "$ci" "$new" "$err"; return 0
  fi

  local title="ci: add secret-scan and coverage jobs (org standard, #581)"
  local body
  body="Adds the org-standard \`secret-scan\` and \`coverage\` jobs to this repo's \`ci.yml\`, copied unchanged from [\`standards/workflows/ci.yml\`](https://github.com/${ORG}/.github/blob/main/standards/workflows/ci.yml). Added here: \`${added}\`$([[ "$seed" = true ]] && printf '%s' ", plus a seeded \`.gitleaks.toml\`")."
  body+=$'\n\n'"These produce the \`Secret scan (gitleaks)\` and \`coverage\` checks, which ${ORG}/.github#581 will make **required** in the \`code-quality\` ruleset once every repo reports them. The coverage job stays green until the repo has tests. If you already measure coverage for your stack, replace the coverage step with yours, but keep the job id and \`name: coverage\`."
  body+=$'\n\n'"No other part of \`ci.yml\` is changed. Opened by \`scripts/backfill-ci-quality-jobs.sh\`."
  outcome="$(sd_deploy_files_via_pr "$repo" "$CBF_BRANCH" "$CBF_LABEL" "$title" "$body" "${files[@]}")" && rc=0 || rc=$?
  rm -f "$ci" "$new" "$err"
  echo "${outcome%% *} ${repo} ${outcome#* }"
  return "$rc"
}

# cbf_check_names <repo> <sha> — print the names of check runs on <sha> that
# passed (success / neutral / skipped; a skipped required check counts as
# passing), one per line.
cbf_check_names() {
  gh api --paginate "repos/$1/commits/$2/check-runs?per_page=100" \
    --jq '.check_runs[] | select(.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") | .name'
}

# cbf_verify_repo <owner/repo> — print PASS or MISSING <contexts>; non-zero unless PASS.
cbf_verify_repo() {
  local repo="$1" branch sha names entry check missing=() pr_sha
  branch="$(gh api "repos/${repo}" --jq '.default_branch')" || { echo "MISSING ${repo} (cannot read repo)"; return 1; }
  sha="$(gh api "repos/${repo}/commits/${branch}" --jq '.sha')" || { echo "MISSING ${repo} (cannot read ${branch})"; return 1; }
  names="$(cbf_check_names "$repo" "$sha")" || { echo "MISSING ${repo} (cannot read check runs)"; return 1; }
  for entry in "${CBF_JOBS[@]}"; do
    check="${entry#*|}"
    grep -qxF "$check" <<< "$names" || missing+=("$check")
  done
  # If CI runs only on pull_request, the default branch tip has no CI checks.
  # Fall back only to a merged PR targeting the default branch; an open or
  # unmerged PR head (e.g. the backfill PR itself) would run the new jobs
  # even though the default branch does not define them yet.
  # Only when the default-branch tip has no check runs at all: if it has CI
  # evidence, a real failure there must not be replaced by an unrelated PR's checks.
  if (( ${#missing[@]} > 0 )) && [[ -z "$(gh api --paginate "repos/${repo}/commits/${sha}/check-runs?per_page=100" --jq '.check_runs[].name' 2>/dev/null)" ]]; then
    pr_sha="$(gh pr list --repo "$repo" --state merged --base "$branch" --limit 1 --json headRefOid --jq '.[0].headRefOid // ""' 2>/dev/null || true)"
    if [[ -n "$pr_sha" ]] && names="$(cbf_check_names "$repo" "$pr_sha")"; then
      missing=()
      for entry in "${CBF_JOBS[@]}"; do
        check="${entry#*|}"
        grep -qxF "$check" <<< "$names" || missing+=("$check")
      done
    fi
  fi
  if (( ${#missing[@]} == 0 )); then echo "PASS ${repo}"; return 0; fi
  local joined; joined="$(printf '"%s", ' "${missing[@]}")"
  echo "MISSING ${repo} ${joined%, }"
  return 1
}

# cbf_fleet_repos — list owner/repo for exactly the repos the code-quality ruleset is applied to.
cbf_fleet_repos() {
  local repos_json classified action repo
  repos_json="$(gh repo list "$ORG" --json name,isArchived,isPrivate,hasIssuesEnabled --limit 1000)" \
    || { echo "::error::failed to list repositories for ${ORG}" >&2; return 1; }
  classified="$(classify_fleet_repos <<< "$repos_json")" || return 1
  while IFS=$'\t' read -r action repo; do
    [[ "$action" = apply ]] && echo "${ORG}/${repo}"
  done <<< "$classified"
  return 0
}

# cbf_main — parse args, then run backfill or verify per repo and report failures via exit code.
cbf_main() {
  local target="" all=false verify=false
  while (( $# > 0 )); do
    case "$1" in
      --repo)
        (( $# >= 2 )) || { echo "::error::--repo requires a value" >&2; return 2; }
        target="$2"; shift 2 ;;
      --all)     all=true; shift ;;
      --verify)  verify=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      *) echo "::error::unknown argument: $1" >&2; return 2 ;;
    esac
  done
  if { [[ -n "$target" ]] && [[ "$all" = true ]]; } || { [[ -z "$target" ]] && [[ "$all" = false ]]; }; then
    echo "::error::usage: $0 [--verify] (--repo <owner/repo> | --all) [--dry-run]" >&2; return 2
  fi
  gh auth status >/dev/null 2>&1 || { echo "::error::GitHub authentication failed — set GH_TOKEN or run 'gh auth login'" >&2; return 1; }

  local repos=() repo failed=0
  if [[ "$all" = true ]]; then
    while IFS= read -r repo; do repos+=("$repo"); done < <(cbf_fleet_repos)
    (( ${#repos[@]} > 0 )) || { echo "::error::no repositories found in ${ORG} — check GH_TOKEN" >&2; return 1; }
  else
    repos=("$(resolve_repo "$target")")
  fi

  for repo in "${repos[@]}"; do
    if [[ "$verify" = true ]]; then
      cbf_verify_repo "$repo" || failed=$((failed + 1))
    else
      cbf_backfill_repo "$repo" || failed=$((failed + 1))
    fi
  done

  if [[ "$verify" = true ]]; then
    if (( failed > 0 )); then
      echo "::error::${failed} of ${#repos[@]} repo(s) do not report both checks yet — do NOT add them to code-quality.json" >&2
      return 1
    fi
    echo "[backfill-ci-quality-jobs] all ${#repos[@]} repo(s) report both checks — safe to add them to code-quality.json (#581 step 3)"
    return 0
  fi
  (( failed == 0 )) || { echo "::error::${failed} repo(s) failed" >&2; return 1; }
}

if [[ "${BASH_SOURCE[0]:-$0}" = "$0" ]]; then
  cbf_main "$@"
fi
