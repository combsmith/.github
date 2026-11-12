#!/usr/bin/env bash
# load-discussion-context.sh — prepare the Discussions an enhancement run may read.
#
# Why this exists:
#   Single-idea and backlog runs refine existing Ideas. This step runs before the
#   model and decides, in tested code, whether the run proceeds and which text it
#   sees. The model reads the file written here instead of querying GitHub.
#
#   - A Discussion must be in the `ideas` category, by a trusted author.
#   - Comments by anyone else are left out of the file.
#   - The "already enhanced" markers count only on trusted comments.
#
# Required env:
#   REPO                      "owner/name"
#   GH_TOKEN                  GitHub token with discussions: read
#   DISCUSSION_CONTEXT_PATH   Where to write the JSON file
#
# Optional env:
#   TARGET_DISCUSSION         Discussion number (single-idea mode; wins over backlog)
#   ENHANCE_BACKLOG           "1" = backlog mode
#   GITHUB_OUTPUT             Receives `proceed=true|false`
#
# Output file:
#   single:  {"mode":"single","discussion":{number,id,title,body,author,comments:[{author,body}]}}
#   backlog: {"mode":"backlog","discussions":[ ...same shape... ]}
#   Neither mode set: no file, and proceed=true (the normal scheduled scan).
#
# Exit codes:
#   0    decision made (see proceed)
#   2    permission lookup failed
#   64   bad usage / missing env
#   1+   underlying gh failure

# shellcheck disable=SC2153  # REPO comes from the environment (checked in main).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-safe.sh
. "${SCRIPT_DIR}/lib/gh-safe.sh"
# shellcheck source=lib/trusted-authors.sh
. "${SCRIPT_DIR}/lib/trusted-authors.sh"

DISCUSSION_FIELDS='
  id
  number
  title
  body
  category { slug }
  author { login __typename }
  comments(first: 100) { nodes { body author { login } } }
'

set_proceed() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'proceed=%s\n' "$1" >>"$GITHUB_OUTPUT"
  fi
  printf '[load-discussion-context] proceed=%s\n' "$1" >&2
}

# Reads an array of raw Discussion nodes. Writes the same array in the shape the
# model reads: comments reduced to trusted authors, with `enhanced` set from them.
shape_discussions() {
  local nodes allowed
  nodes=$(cat)
  allowed=$(printf '%s' "$nodes" \
    | jq -r '[.[] | .author.login // empty, (.comments.nodes[]? | .author.login // empty)] | unique | .[]' \
    | trusted_authors_allowlist "$REPO") || return 2
  printf '%s' "$nodes" | jq -c --argjson allowed "$allowed" '
    def trusted: (. // "") as $a | $allowed | index($a) != null;
    [.[] | {
      number, id, title, body,
      category: .category.slug,
      author: (.author.login // null),
      author_type: (.author.__typename // null),
      author_trusted: (.author.login | trusted),
      comments: [.comments.nodes[]? | select(.author.login | trusted) | {author: .author.login, body}]
    } | .enhanced = (.comments | any(
        .body | contains("<!-- feature-ideation:enhanced -->") or contains("<!-- idea-enhancer:enhanced -->")
      ))]'
}

model_fields() {
  jq -c 'del(.category, .author_type, .author_trusted, .enhanced)'
}

load_single() {
  local owner="${REPO%%/*}" name="${REPO##*/}"
  local query response discussion
  query="query(\$owner: String!, \$name: String!, \$number: Int!) {
    repository(owner: \$owner, name: \$name) { discussion(number: \$number) { ${DISCUSSION_FIELDS} } }
  }"
  response=$(gh_safe_graphql -f query="$query" -f owner="$owner" -f name="$name" -F number="$TARGET_DISCUSSION")
  discussion=$(printf '%s' "$response" | jq -c '[.data.repository.discussion]' | shape_discussions) || return $?
  discussion=$(printf '%s' "$discussion" | jq -c '.[0]')

  local reason=""
  if [[ "$(printf '%s' "$discussion" | jq -r '.category')" != "ideas" ]]; then
    reason="not in the Ideas category"
  elif [[ "$(printf '%s' "$discussion" | jq -r '.author_trusted')" != "true" ]]; then
    reason="author does not have write access"
  elif [[ "$(printf '%s' "$discussion" | jq -r '.enhanced')" = "true" ]]; then
    reason="already enhanced"
  fi
  if [[ -n "$reason" ]]; then
    printf '::notice title=Feature ideation::Discussion %s not enhanced: %s.\n' "$TARGET_DISCUSSION" "$reason"
    set_proceed false
    return 0
  fi

  printf '%s' "$discussion" | model_fields \
    | jq -c '{mode: "single", discussion: .}' >"$DISCUSSION_CONTEXT_PATH"
  set_proceed true
}

load_backlog() {
  local owner="${REPO%%/*}" name="${REPO##*/}"
  local query page nodes='[]' cursor=""
  query="query(\$owner: String!, \$name: String!, \$cursor: String) {
    repository(owner: \$owner, name: \$name) {
      discussions(first: 50, after: \$cursor, states: [OPEN]) {
        pageInfo { hasNextPage endCursor }
        nodes { ${DISCUSSION_FIELDS} }
      }
    }
  }"
  while :; do
    if [[ -n "$cursor" ]]; then
      page=$(gh_safe_graphql -f query="$query" -f owner="$owner" -f name="$name" -f cursor="$cursor")
    else
      page=$(gh_safe_graphql -f query="$query" -f owner="$owner" -f name="$name")
    fi
    nodes=$(jq -cn --argjson a "$nodes" --argjson b "$(printf '%s' "$page" | jq -c '.data.repository.discussions.nodes // []')" '$a + $b')
    [[ "$(printf '%s' "$page" | jq -r '.data.repository.discussions.pageInfo.hasNextPage // false')" = "true" ]] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.repository.discussions.pageInfo.endCursor')
  done

  local shaped candidates
  shaped=$(printf '%s' "$nodes" | shape_discussions) || return $?
  candidates=$(printf '%s' "$shaped" | jq -c '[.[]
    | select(.category == "ideas" and .author_type == "User" and .author_trusted and (.enhanced | not))
    | del(.category, .author_type, .author_trusted, .enhanced)]')

  printf '%s' "$candidates" | jq -c '{mode: "backlog", discussions: .}' >"$DISCUSSION_CONTEXT_PATH"
  printf '[load-discussion-context] backlog: %s of %s open Discussions are candidates\n' \
    "$(printf '%s' "$candidates" | jq 'length')" "$(printf '%s' "$nodes" | jq 'length')" >&2
  set_proceed true
}

main() {
  if [[ ! ${REPO:-} =~ ^[^/]+/[^/]+$ ]]; then
    printf '[load-discussion-context] REPO must be in owner/name format\n' >&2
    return 64
  fi
  if [[ -z "${GH_TOKEN:-}" ]] || [[ -z "${DISCUSSION_CONTEXT_PATH:-}" ]]; then
    printf '[load-discussion-context] GH_TOKEN and DISCUSSION_CONTEXT_PATH are required\n' >&2
    return 64
  fi

  if [[ -n "${TARGET_DISCUSSION:-}" ]]; then
    if [[ ! $TARGET_DISCUSSION =~ ^[1-9][0-9]*$ ]]; then
      printf '[load-discussion-context] TARGET_DISCUSSION must be a positive integer\n' >&2
      return 64
    fi
    load_single
  elif [[ "${ENHANCE_BACKLOG:-0}" = "1" ]]; then
    load_backlog
  else
    set_proceed true
  fi
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
