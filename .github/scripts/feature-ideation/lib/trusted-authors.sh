#!/usr/bin/env bash
# trusted-authors.sh — decide whose text may reach the analyst.
#
# Why this exists:
#   Repositories here are public, so anyone can open an issue or a Discussion.
#   Only text from people with write access (and from this pipeline's own bot)
#   is handed to the model.
#
#   Trust is read from the repository permission API rather than from
#   `authorAssociation`: an association read through an API depends on what the
#   caller may see, and org memberships here are private.
#
# Contract:
#   - admin or write          → trusted
#   - read, none, or no user  → untrusted
#   - any other API failure   → exit 2. Never downgraded to "untrusted", which
#                               would quietly empty the signals.
#
# Usage:
#   source .github/scripts/feature-ideation/lib/trusted-authors.sh
#   trusted_author_check "owner/repo" "login"
#   printf '%s\n' alice bob | trusted_authors_allowlist "owner/repo"

set -euo pipefail

# Spellings of the pipeline's own bot: GraphQL, REST and `gh --json author`.
TRUSTED_PIPELINE_AUTHORS=(
  "github-actions"
  "github-actions[bot]"
  "app/github-actions"
)

# trusted_author_check <repo> <login>: 0 trusted, 1 untrusted, 2 API failure.
trusted_author_check() {
  local repo="$1"
  local login="$2"

  local known
  for known in "${TRUSTED_PIPELINE_AUTHORS[@]}"; do
    [[ "$login" = "$known" ]] && return 0
  done

  # Other bots and malformed names never have a collaborator record. Checking
  # the shape also keeps the value safe to place in the API path.
  if [[ ! $login =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    return 1
  fi

  local permission rc tmp_err
  tmp_err=$(mktemp)
  set +e
  permission=$(gh api "repos/${repo}/collaborators/${login}/permission" --jq '.permission' 2>"$tmp_err")
  rc=$?
  set -e
  local stderr
  stderr=$(cat "$tmp_err")
  rm -f "$tmp_err"

  if [[ "$rc" -ne 0 ]]; then
    case "$stderr" in
      *"HTTP 404"*) return 1 ;;
    esac
    printf '[trusted-authors] permission lookup failed: exit=%s stderr=%s\n' "$rc" "$stderr" >&2
    return 2
  fi

  case "$permission" in
    admin | write) return 0 ;;
    *) return 1 ;;
  esac
}

# trusted_authors_allowlist <repo>: reads one login per line on stdin, writes a
# JSON array of the trusted ones. Exits 2 on an API failure.
trusted_authors_allowlist() {
  local repo="$1"
  local allowed='[]'
  local login rc
  while IFS= read -r login; do
    [[ -n "$login" ]] || continue
    rc=0
    trusted_author_check "$repo" "$login" || rc=$?
    case "$rc" in
      0) allowed=$(printf '%s' "$allowed" | jq -c --arg login "$login" '. + [$login]') ;;
      1) ;;
      *) return 2 ;;
    esac
  done
  printf '%s' "$allowed"
}
