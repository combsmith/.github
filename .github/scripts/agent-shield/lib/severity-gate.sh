#!/usr/bin/env bash
# Severity gate for the AgentShield reusable (issue #1436).
#
# The scanner's --min-severity only filters the report, and its exit code only
# reflects critical findings. This gate reads the scanner's JSON report and
# decides pass or fail at the configured threshold.
#
# Pure decision: no network calls. Anything it cannot verify fails closed.
#
# Report schema read here (ecc-agentshield 1.4.0 and 1.6.0, `--format json`):
#   { "findings": [ { "severity": "critical|high|medium|low|info", "title": "...",
#                     "description": "...", "file": "...", "line": 12 } ],
#     "summary": { "totalFindings": 1, ... } }
#
# Finding text comes from the scanned repository, so it is cleaned before it
# reaches the log, and `evidence` is never printed.
#
# Tested by test/workflows/agent-shield/severity-gate.bats.

# agent_shield_severity_gate THRESHOLD REPORT_FILE
#   Returns 0 when no finding is at or above THRESHOLD, 1 otherwise. Also returns
#   1 for an unknown threshold, or a report that is unreadable or off-schema.
agent_shield_severity_gate() {
  local threshold="$1" report="$2" out verdict

  case "$threshold" in
    critical | high | medium | low | info) ;;
    *)
      echo "::error::AgentShield: min-severity must be one of critical, high, medium, low, info"
      return 1
      ;;
  esac

  # -s: exactly one JSON document is accepted, so stray output around the report
  # is treated as off-schema rather than ignored.
  out=$(jq -rs --arg threshold "$threshold" '
    def levels: ["critical", "high", "medium", "low", "info"];
    def rank: . as $s | levels | index($s);
    def safe: tostring
      | gsub("[[:cntrl:]]+"; " ")
      | gsub(":(?=:)"; ":​")
      | gsub("##\\["; "#​#[");
    def location: (.file // "unknown" | safe)
      + (if .line then ":" + (.line | safe) else "" end);

    if length != 1 then "invalid\texpected one JSON document"
    else .[0] as $report
      | if ($report | type) != "object" or ($report.findings | type) != "array" then
          "invalid\tfindings list missing"
        elif ($report.summary.totalFindings // null) != ($report.findings | length) then
          "invalid\tsummary does not match the findings list"
        elif any($report.findings[];
            (type != "object") or ((.severity | type) != "string") or (.severity | rank) == null) then
          "invalid\tfinding with an unknown severity"
        else
          ($threshold | rank) as $limit
          | [$report.findings[] | select((.severity | rank) <= $limit)] as $hits
          | if ($hits | length) == 0 then
              "pass\t\($report.findings | length)"
            else
              "fail\t\($hits | length)",
              ($hits | sort_by(.severity | rank)[]
                | "  [\(.severity | ascii_upcase)] \(.title // "untitled" | safe) (\(location))",
                  "    \(.description // "" | safe)")
            end
        end
    end
  ' "$report" 2>/dev/null) || out=""

  verdict="${out%%$'\n'*}"
  case "$verdict" in
    pass$'\t'*)
      echo "AgentShield: no findings at or above ${threshold} (${verdict#*$'\t'} reported)"
      return 0
      ;;
    fail$'\t'*)
      echo "::error::AgentShield: ${verdict#*$'\t'} finding(s) at or above ${threshold}"
      printf '%s\n' "${out#*$'\n'}"
      return 1
      ;;
    invalid$'\t'*)
      echo "::error::AgentShield: cannot trust the scan report: ${verdict#*$'\t'}"
      return 1
      ;;
    *)
      echo "::error::AgentShield: could not read the scan report"
      return 1
      ;;
  esac
}
