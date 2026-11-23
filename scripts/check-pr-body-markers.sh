#!/usr/bin/env bash
set -euo pipefail
# check-pr-body-markers.sh — fail when a pull request's title and body carry a marker that would
# act on its own once the body is the squash commit message (issue #1571): a BREAKING CHANGE:
# line without '!' in the title, or a skip-CI marker. Logic: scripts/lib/pr-body-markers.sh.
#
# Usage: PR_TITLE=... PR_BODY=... check-pr-body-markers.sh
# The workflow passes both through the environment, never interpolated into the script.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/pr-body-markers.sh
source "${SCRIPT_DIR}/lib/pr-body-markers.sh"

findings=""
if findings="$(pr_body_marker_findings "${PR_TITLE:-}" "${PR_BODY:-}")"; then
  echo "pr-body-markers: clean"
  exit 0
fi
while IFS= read -r line; do
  [[ -n "$line" ]] && printf '::error::%s\n' "$line"
done <<< "$findings"
echo "Rules: docs/initiatives/pull-request-and-commit-prose-adr.md (combsmith/.github)." >&2
exit 1
