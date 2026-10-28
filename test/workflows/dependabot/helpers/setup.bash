#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture constants are read by the .bats files
# Common helpers for the Dependabot merge-gate bats suite (#1399, #1400).

TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT
TT_LIB_DIR="${TT_REPO_ROOT}/.github/scripts/dependabot/lib"
export TT_LIB_DIR

# Fixture constants, used by the .bats files that load this helper.
HEAD_SHA="1111111111111111111111111111111111111111"
DEP_SHA="2222222222222222222222222222222222222222"
OTHER_SHA="3333333333333333333333333333333333333333"
APP_SLUG_FIXTURE="my-merge-app"
APP_LOGIN_FIXTURE="my-merge-app[bot]"

# tt_setup — scratch dir, fixture dir and a fixture-driven `gh` stub on PATH.
tt_setup() {
  TT_TMP="$(mktemp -d)"
  FIX_DIR="${TT_TMP}/fixtures"
  TT_BIN="${TT_TMP}/bin"
  TT_WORK="${TT_TMP}/work"
  mkdir -p "$FIX_DIR" "$TT_BIN" "$TT_WORK"
  ln -s "$TT_REPO_ROOT" "${TT_WORK}/.dependabot-tooling"
  export FIX_DIR TT_TMP TT_WORK
  _tt_install_gh_stub
  PATH="${TT_BIN}:${PATH}"
  export PATH
}

tt_teardown() {
  if [ -n "${TT_TMP:-}" ] && [ -d "${TT_TMP}" ]; then
    rm -rf "${TT_TMP}"
  fi
}

_tt_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# tt_fixture ENDPOINT BODY [RC] — serve BODY for `gh api ENDPOINT`.
tt_fixture() {
  local key
  key="$(_tt_key "$1")"
  printf '%s\n' "$2" > "${FIX_DIR}/${key}.json"
  rm -f "${FIX_DIR}/${key}.rc"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "${FIX_DIR}/${key}.rc"; fi
}

# ── `gh` stub ────────────────────────────────────────────────────────────────
# Every call is appended to calls.log as "TOKEN=<GH_TOKEN> <args>".
#   gh api graphql … -F number=N   → graphql_N.json
#   gh api ENDPOINT (GET)          → <key(ENDPOINT)>.json (404 when absent);
#                                    `--paginate --slurp` wraps it in a page array
#   gh api ENDPOINT -X PUT|POST    → recorded in writes.log with its fields;
#                                    succeeds unless <key>.rc exists
#   gh pr list … --jq E            → pr_list.json through jq
#   gh pr view N --json … [--jq E] → pr_view_N.json (through jq when given)
#   gh pr merge / gh pr review     → recorded in writes.log; `pr_merge.rc` fails
_tt_install_gh_stub() {
  cat > "${TT_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'TOKEN=%s %s\n' "${GH_TOKEN:-}" "$*" >> "${FIX_DIR}/calls.log"
_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

_emit() { # BODY JQ
  if [ -n "$2" ]; then printf '%s' "$1" | jq -r "$2"; else printf '%s\n' "$1"; fi
}

if [ "$1" = "api" ]; then
  shift
  endpoint="" jq_expr="" number="" method="GET" paginate=false slurp=false fields=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jq|-q) jq_expr="$2"; shift 2 ;;
      -X|--method) method="$2"; shift 2 ;;
      -H) shift 2 ;;
      --paginate) paginate=true; shift ;;
      --slurp) slurp=true; shift ;;
      --silent) shift ;;
      -f|-F)
        case "$2" in number=*) number="${2#number=}" ;; query=*) ;; *) fields="${fields} $2" ;; esac
        shift 2 ;;
      *) endpoint="$1"; shift ;;
    esac
  done
  if [ "$endpoint" = "graphql" ]; then
    key="graphql_${number}"
  else
    key="$(_key "$endpoint")"
  fi
  if [ "$method" != "GET" ]; then
    printf 'TOKEN=%s %s %s%s\n' "${GH_TOKEN:-}" "$method" "$endpoint" "$fields" >> "${FIX_DIR}/writes.log"
    if [ -f "${FIX_DIR}/${key}.rc" ]; then exit "$(cat "${FIX_DIR}/${key}.rc")"; fi
    exit 0
  fi
  if [ ! -f "${FIX_DIR}/${key}.json" ]; then
    echo '{"message":"Not Found","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  body="$(cat "${FIX_DIR}/${key}.json")"
  if [ -f "${FIX_DIR}/${key}.rc" ]; then
    printf '%s\n' "$body"; exit "$(cat "${FIX_DIR}/${key}.rc")"
  fi
  if [ "$paginate" = true ] && [ "$slurp" = true ]; then body="[${body}]"; fi
  _emit "$body" "$jq_expr"
  exit $?
fi

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  shift 2; jq_expr=""
  while [ "$#" -gt 0 ]; do case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac; done
  _emit "$(cat "${FIX_DIR}/pr_list.json" 2>/dev/null || echo '[]')" "$jq_expr"
  exit $?
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  pr="$3"; shift 3; jq_expr=""
  while [ "$#" -gt 0 ]; do case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac; done
  [ -f "${FIX_DIR}/pr_view_${pr}.json" ] || exit 1
  _emit "$(cat "${FIX_DIR}/pr_view_${pr}.json")" "$jq_expr"
  exit $?
fi

if [ "$1" = "pr" ] && { [ "$2" = "merge" ] || [ "$2" = "review" ]; }; then
  printf 'TOKEN=%s %s\n' "${GH_TOKEN:-}" "$*" >> "${FIX_DIR}/writes.log"
  if [ "$2" = "merge" ] && [ -f "${FIX_DIR}/pr_merge.rc" ]; then exit "$(cat "${FIX_DIR}/pr_merge.rc")"; fi
  exit 0
fi

exit 0
STUB
  chmod +x "${TT_BIN}/gh"
}

# ── fixture builders ─────────────────────────────────────────────────────────

# tt_check_run NAME STATUS CONCLUSION — one GraphQL CheckRun node.
tt_check_run() {
  jq -cn --arg n "$1" --arg s "$2" --arg c "$3" \
    '{__typename:"CheckRun",name:$n,status:$s,conclusion:(if $c == "" then null else $c end)}'
}

# tt_status NAME STATE — one GraphQL StatusContext node.
tt_status() {
  jq -cn --arg n "$1" --arg s "$2" '{__typename:"StatusContext",context:$n,state:$s}'
}

# tt_pr_state NODES_JSON [MERGEABLE] [AUTO_MERGE true|false] [HEAD] [ROLLUP_SHA] [HAS_NEXT]
#   A GraphQL pullRequest object for the check gate.
tt_pr_state() {
  jq -cn --argjson nodes "$1" --arg m "${2:-MERGEABLE}" --arg am "${3:-true}" \
    --arg head "${4:-$HEAD_SHA}" --arg oid "${5:-${4:-$HEAD_SHA}}" --arg next "${6:-false}" '
    {headRefOid:$head, baseRefName:"main", mergeable:$m,
     autoMergeRequest:(if $am == "true" then {enabledAt:"2026-01-01T00:00:00Z"} else null end),
     commits:{nodes:[{commit:{oid:$oid,statusCheckRollup:{contexts:{
       pageInfo:{hasNextPage:($next == "true")}, nodes:$nodes}}}}]}}'
}

# tt_commit SHA AUTHOR COMMITTER [VERIFIED true|false] [PARENTS]
tt_commit() {
  jq -cn --arg sha "$1" --arg a "$2" --arg c "$3" --arg v "${4:-true}" --argjson p "${5:-1}" '
    {sha:$sha,
     author:(if $a == "" then null else {login:$a} end),
     committer:(if $c == "" then null else {login:$c} end),
     parents:[range(0;$p) | {sha:"p\(.)"}],
     commit:{verification:{verified:($v == "true"), reason:(if $v == "true" then "valid" else "unsigned" end)}}}'
}

# tt_pr_rest [HEAD] [COMMIT_COUNT] — REST pull request object.
tt_pr_rest() {
  jq -cn --arg head "${1:-$HEAD_SHA}" --argjson n "${2:-1}" '{number:5,head:{sha:$head},base:{ref:"main"},commits:$n}'
}

# tt_seed_pr STATE_JSON COMMITS_JSON [REQUIRED_RULES_JSON]
#   PR #5 (head branch dependabot/npm/foo, up to date with main) with the given
#   GraphQL state, REST commits and base-branch rules. Also writes a
#   `gh pr view` fixture mirroring the state (used by the pre-fix workflow).
tt_seed_pr() {
  local state="$1" commits="$2" rules="${3:-[]}" head count
  head=$(jq -r '.headRefOid' <<<"$state")
  count=$(jq 'length' <<<"$commits")
  printf '%s\n' '[{"number":5,"headRefName":"dependabot/npm/foo"}]' > "${FIX_DIR}/pr_list.json"
  tt_fixture "repos/owner/repo/compare/main...dependabot/npm/foo" '{"behind_by":0}'
  printf '%s\n' "{\"data\":{\"repository\":{\"pullRequest\":${state}}}}" > "${FIX_DIR}/graphql_5.json"
  tt_fixture "repos/owner/repo/rules/branches/main?per_page=100" "$rules"
  tt_fixture "repos/owner/repo/pulls/5" "$(tt_pr_rest "$head" "$count")"
  tt_fixture "repos/owner/repo/pulls/5/commits?per_page=100" "$commits"
  jq -c '{autoMergeRequest, mergeable,
          statusCheckRollup: [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]]}' \
    <<<"$state" > "${FIX_DIR}/pr_view_5.json"
}

# tt_extract_run WORKFLOW JOB STEP_NAME — print a step's run block.
tt_extract_run() {
  yq -r ".jobs.\"$2\".steps[] | select(.name == \"$3\") | .run" "$1"
}
