# shellcheck shell=bash
# scripts/lib/analysis-inputs.sh — input check of the `analyze` job of
# compliance-audit-and-improvement.yml (#1616).
#
# Audit run 46072704625 ran the analysis with no compliance report: the
# download was skipped and the model found an absent directory. Each input is
# now checked before the model runs, and its status (with the producing job's
# result) is handed to the prompt, so a missing input is reported, never
# guessed at.
#
#   analysis_input_status — pure: `present` or `missing (producing job result: …)`
#
# This library is `set -euo pipefail`-safe and does not call `set` itself.

# analysis_input_status <file> <job_result>
#   <file>       — the input file the model will read
#   <job_result> — `needs.<job>.result` of the job that produces it
#   Echo `present` when <file> exists and holds more than whitespace, else
#   `missing (producing job result: <job_result>)` (`unknown` when empty).
analysis_input_status() {
  local file="$1" result="${2:-}"
  if [[ ! -f "$file" ]]; then
    echo "missing (producing job result: ${result:-unknown})"
    return 0
  fi
  if grep -q '[^[:space:]]' "$file" 2>/dev/null; then
    echo "present"
  else
    echo "missing (producing job result: ${result:-unknown})"
  fi
}
