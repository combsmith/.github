#!/usr/bin/env bash
set -euo pipefail
# check-pr-body-markers.sh — fail when a pull request's title and body carry a marker that would
# act on its own once the body is the squash commit message (issue #1571): a BREAKING CHANGE:
# line without '!' in the title, or a skip-CI marker. Logic: scripts/lib/pr-body-markers.sh.
#
# Usage: PR_TITLE=... PR_BODY=... [PR_COMMITS_FILE=path] check-pr-body-markers.sh
# The workflow passes the title and body through the environment, never interpolated into the
# script, and the branch's commit messages in a file (read with `gh` in the glue), each message
# ended by a NUL byte so that each commit's own subject can be checked. A file with no NUL is read
# as one message.
#
# Exit 0: clean. Exit 3: findings, the verdict on the pull request's content. Exit 2: a caller
# fault. Any other exit (1 included, as from a failed `source` under set -e) is a checker fault.
# The lib's own greps run without set -e, so a fault inside them is not caught here.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pr-body-markers.sh
source "${SCRIPT_DIR}/lib/pr-body-markers.sh"

# An unset title or body is a caller fault, not a clean pull request (an empty body is valid: the
# workflow passes it as an empty string), so fail closed instead of printing "clean".
if [[ -z "${PR_TITLE+x}" || -z "${PR_BODY+x}" ]]; then
  echo "::error::PR_TITLE and PR_BODY must be set (an empty body is fine)" >&2
  exit 2
fi

commits=()
if [[ -n "${PR_COMMITS_FILE:-}" ]]; then
  [[ -r "$PR_COMMITS_FILE" ]] || { echo "::error::cannot read the commit messages file" >&2; exit 2; }
  msg=""
  while IFS= read -r -d '' msg || [[ -n "$msg" ]]; do
    commits+=("$msg")
    msg=""
  done < "$PR_COMMITS_FILE"
fi
findings="" rc=0
findings="$(pr_body_marker_findings "$PR_TITLE" "$PR_BODY" ${commits[@]+"${commits[@]}"})" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo "pr-body-markers: clean"
  exit 0
fi
# Only the findings return (1) is a verdict; any other status is a fault and keeps its own code.
if [[ "$rc" -ne 1 ]]; then
  echo "::error::the marker check failed with status $rc" >&2
  exit "$rc"
fi
while IFS= read -r line; do
  [[ -n "$line" ]] && printf '::error::%s\n' "$line"
done <<< "$findings"
echo "Why: combsmith/.github#1571 (only the title's '!' marks a breaking change)." >&2
exit 3
