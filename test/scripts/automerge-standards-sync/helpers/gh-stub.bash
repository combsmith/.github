# shellcheck shell=bash
# Shared fake `gh` for the automerge-standards-sync suites.
#
# Every invocation is logged to $GH_CALLS. Reads are served from env fixtures so
# a test can model any PR state:
#
#   GH_PR_VIEW_JSON      `gh pr view --json …` blob (the eligibility read)
#   GH_HEAD_SHA_AFTER    head SHA returned by the post-approval re-check
#                        (`gh pr view --json headRefOid --jq …`); default
#                        $GH_FIXTURE_HEAD, i.e. the head did not move
#   GH_COMMITS_NDJSON    `gh api --paginate …/pulls/N/commits --jq '.[]'` output
#   GH_FILES_NDJSON      `gh api --paginate …/pulls/N/files --jq '.[]'` output
#   GH_ACTIVITY_NDJSON   `gh api --paginate …/activity?ref=… --jq '.[]'` output
#   GH_*_RC              non-zero → that read fails
#
# Defaults model a clean deploy: one commit by $GH_FIXTURE_LOGIN (default
# don-petry) at $GH_FIXTURE_HEAD, touching one deployable stub, pushed by the
# same identity.

# shellcheck disable=SC2034  # read by the suites that load this helper
GH_FIXTURE_HEAD="headsha0000000000000000000000000000000001"

install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
login="${GH_FIXTURE_LOGIN:-don-petry}"
head="${GH_FIXTURE_HEAD:-headsha0000000000000000000000000000000001}"
default_commits="$(jq -nc --arg l "$login" --arg h "$head" \
  '{sha: $h, author: {login: $l}, committer: {login: $l}, commit: {verification: {verified: false}}}')"
default_files='{"filename":".github/workflows/dev-lead.yml","status":"modified"}'
default_activity="$(jq -nc --arg l "$login" --arg h "$head" \
  '{activity_type: "push", actor: {login: $l}, after: $h, timestamp: "2026-10-27T00:00:01Z"}')"

endpoint=""
for a in "$@"; do
  case "$a" in repos/*) endpoint="$a" ;; esac
done

case "$1 ${2:-}" in
  "pr view")
    if printf '%s ' "$@" | grep -q -- '--jq'; then
      printf '%s\n' "${GH_HEAD_SHA_AFTER:-$head}"
    else
      printf '%s' "${GH_PR_VIEW_JSON:-null}"
    fi
    exit 0 ;;
  "pr list")   printf '%s' "${GH_PR_LIST_JSON:-[]}" ; exit 0 ;;
  "pr review") exit 0 ;;
  "pr merge")  exit "${GH_MERGE_RC:-0}" ;;
  "api user")  printf '%s' "${GH_API_USER_LOGIN:-donpetry-bot}" ; exit 0 ;;
  "auth status") exit 0 ;;
esac

if [ "$1" = "api" ]; then
  case "$endpoint" in
    */pulls/*/commits*)
      [ "${GH_COMMITS_RC:-0}" -ne 0 ] && exit "$GH_COMMITS_RC"
      printf '%s\n' "${GH_COMMITS_NDJSON-$default_commits}" ; exit 0 ;;
    */pulls/*/files*)
      [ "${GH_FILES_RC:-0}" -ne 0 ] && exit "$GH_FILES_RC"
      printf '%s\n' "${GH_FILES_NDJSON-$default_files}" ; exit 0 ;;
    */activity*)
      [ "${GH_ACTIVITY_RC:-0}" -ne 0 ] && exit "$GH_ACTIVITY_RC"
      printf '%s\n' "${GH_ACTIVITY_NDJSON-$default_activity}" ; exit 0 ;;
    */pulls/*/reviews*)
      exit "${GH_REVIEW_RC:-0}" ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# commit_ndjson <sha> <author-login> <committer-login> [verified]
commit_ndjson() {
  jq -nc --arg s "$1" --arg a "$2" --arg c "$3" --argjson v "${4:-false}" \
    '{sha: $s, author: {login: $a}, committer: {login: $c}, commit: {verification: {verified: $v}}}'
}

# A bare `! cmd` never fails a bats test (errexit ignores negated commands), so
# negative assertions go through these helpers, which return 1 explicitly.
# refute_call <ERE> — no logged gh invocation matches.
refute_call() {
  if grep -qE -- "$1" "$GH_CALLS"; then
    echo "unexpected gh call matching: $1" >&2
    grep -E -- "$1" "$GH_CALLS" >&2
    return 1
  fi
}

# refute_output_has <fixed-string> — $output does not contain it.
refute_output_has() {
  # shellcheck disable=SC2154  # $output is set by bats `run`
  if printf '%s\n' "$output" | grep -qF -- "$1"; then
    echo "unexpected output containing: $1" >&2
    return 1
  fi
}

# file_ndjson <filename> [status]
file_ndjson() {
  jq -nc --arg f "$1" --arg s "${2:-modified}" '{filename: $f, status: $s}'
}

# push_ndjson <actor> <after-sha> <timestamp> [activity_type]
push_ndjson() {
  jq -nc --arg a "$1" --arg h "$2" --arg t "$3" --arg k "${4:-push}" \
    '{activity_type: $k, actor: {login: $a}, after: $h, timestamp: $t}'
}
