#!/usr/bin/env bats
# Issue #1226 (Gap 2) — the agent rate-limit guard must not FAIL OPEN on an
# ADR-0007 collapsed repo.
#
# A collapsed repo serves each agent role from ONE job of agent-ingress.yml; the
# per-role workflow no longer exists. Before this fix, both
# arl_count_concurrent_runs (scripts/lib/agent-rate-limit.sh) and argate_fetch_runs
# (scripts/agent-rate-limit-gate.sh) enumerated runs BY WORKFLOW, got nothing, and
# read concurrency as 0 — so the guard never throttled that repo. Worse, a
# permanent "no such workflow" was indistinguishable from a transient API blip.
#
# Now:
#   - a permanent missing workflow falls back to agent-ingress.yml runs attributed
#     by role-bearing JOB (consistent with .github-private run-attribution.sh);
#   - with neither a workflow nor an ingress the count is UNRESOLVED (never 0),
#     and the admission gate fails closed (defer);
#   - a transient failure still degrades permissively with its existing warning.
#
# `gh` is a fixture-driven fake; no network is touched.

bats_require_minimum_version 1.5.0

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
LIB="$ROOT/scripts/lib/agent-rate-limit.sh"
GATE="$ROOT/scripts/agent-rate-limit-gate.sh"
INGRESS_LIB="$ROOT/scripts/lib/agent-ingress.sh"

setup() {
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/ingress.XXXXXX")"
  export TMP
  export GH_FIX="$TMP/fix"
  mkdir -p "$GH_FIX/runs" "$GH_FIX/jobs" "$TMP/bin"

  # Fixture-driven fake gh.
  #   gh run list [--repo R] --workflow W …  → key = <R or _local>__<W> ('/' → '_')
  #     $GH_FIX/runs/<key>.json       → printed, exit 0
  #     $GH_FIX/runs/<key>.transient  → "HTTP 502" on stderr, exit 1
  #     (no fixture)                  → gh's real missing-workflow error, exit 1
  #   gh api repos/<o>/<r>/actions/runs/<id>/jobs…  → $GH_FIX/jobs/<id>.json or 404
  cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_STUB_LOG:-}" ]; then printf '%q ' "$@" >>"$GH_STUB_LOG"; printf '\n' >>"$GH_STUB_LOG"; fi
if [ "${1:-} ${2:-}" = "run list" ]; then
  shift 2
  repo="_local" wf="" st=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --workflow|-w) wf="$2"; shift 2 ;;
      --status) st="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  key="${repo//\//_}__${wf}"
  if [ -f "$GH_FIX/runs/$key.json" ]; then
    if [ -n "$st" ]; then jq -c --arg s "$st" 'map(select(.status == $s))' "$GH_FIX/runs/$key.json"; else cat "$GH_FIX/runs/$key.json"; fi
    exit 0
  fi
  if [ -f "$GH_FIX/runs/$key.forbidden" ]; then echo "HTTP 404: Not Found (https://api.github.com/repos/o/r)" >&2; exit 1; fi
  if [ -f "$GH_FIX/runs/$key.transient" ]; then echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; fi
  echo "could not find any workflows named ${wf}" >&2
  exit 1
fi
if [ "${1:-}" = "api" ]; then
  if [[ "${2:-}" == *contents/.github/workflows/agent-ingress.yml ]] && [ -f "$GH_FIX/ingress.b64" ]; then
    printf '{"type":"file","encoding":"base64","content":"%s"}' "$(cat "$GH_FIX/ingress.b64")"; exit 0
  fi
  if [[ "${2:-}" =~ /actions/runs/([0-9]+)/jobs ]]; then
    id="${BASH_REMATCH[1]}"
    if [ -f "$GH_FIX/jobs/$id.json" ]; then cat "$GH_FIX/jobs/$id.json"; exit 0; fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1
  fi
fi
exit 0
STUB
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  export PATH
  export GH_STUB_LOG="$TMP/gh.log"
  : >"$GH_STUB_LOG"
  unset AGENT_RATE_LIMITS_ORG_REPOS GITHUB_RUN_ID
}

teardown() { rm -rf "$TMP"; }

write_config() {  # agent max cooldown daily cb_threshold cb_backoff
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  jq -n --arg agent "$1" --argjson max "$2" --argjson cooldown "$3" --argjson daily "$4" \
    --argjson cbt "$5" --argjson cbb "$6" '{
      status: "signed-off", _schema_version: 1,
      agent_types: { ($agent): {
        max_concurrent_runs: $max, max_runtime_minutes: 30,
        cooldown_minutes: $cooldown, daily_run_budget: $daily,
        circuit_breaker: { consecutive_failure_threshold: $cbt, backoff_minutes: $cbb }
      } },
      org_wide: {}, exempt_actors: ["dependabot[bot]"], exempt_labels: ["security"]
    }' >"$AGENT_RATE_LIMITS_CONFIG"
}

# runs_fixture <repo|_local> <workflow> <json>
runs_fixture() { printf '%s' "$3" >"$GH_FIX/runs/${1//\//_}__$2.json"; }
transient_fixture() { : >"$GH_FIX/runs/${1//\//_}__$2.transient"; }
# jobs_fixture <run_id> <jobs-json-array>
jobs_fixture() { printf '{"total_count":0,"jobs":%s}' "$2" >"$GH_FIX/jobs/$1.json"; }

# A collapsed repo with in-flight ingress runs: two carry a live dev-lead job,
# one carries only a live pr-review-mention job (dev-lead skipped), and one
# finished run carries a completed dev-lead job.
seed_collapsed() {
  local repo="$1"
  runs_fixture "$repo" agent-ingress.yml '[
    {"databaseId":101,"status":"in_progress","conclusion":"","createdAt":"2026-10-02T10:00:00Z"},
    {"databaseId":102,"status":"in_progress","conclusion":"","createdAt":"2026-10-02T10:01:00Z"},
    {"databaseId":103,"status":"queued","conclusion":"","createdAt":"2026-10-02T10:02:00Z"},
    {"databaseId":104,"status":"completed","conclusion":"success","createdAt":"2026-10-02T09:00:00Z"}
  ]'
  jobs_fixture 101 '[{"name":"dev-lead / run","status":"in_progress","conclusion":null},{"name":"pr-review-mention","status":"completed","conclusion":"skipped"}]'
  jobs_fixture 102 '[{"name":"dev-lead","status":"completed","conclusion":"skipped"},{"name":"pr-review-mention / review","status":"in_progress","conclusion":null}]'
  jobs_fixture 103 '[{"name":"dev-lead","status":"queued","conclusion":null},{"name":"pr-review-mention","status":"completed","conclusion":"skipped"}]'
  jobs_fixture 104 '[{"name":"dev-lead / run","status":"completed","conclusion":"success"}]'
}

# ===========================================================================
# Pure — agent_ingress_role_runs / agent_ingress_gh_error_kind
# ===========================================================================

@test "agent_ingress_role_runs: one record per run in which the role actually ran" {
  run bash -c 'source "$1"; agent_ingress_role_runs dev-lead <<<"$2" | jq -c "map(.databaseId)"' _ "$INGRESS_LIB" '[
    {"databaseId":1,"status":"in_progress","createdAt":"t1","jobs":[{"name":"dev-lead / a","status":"in_progress","conclusion":null},{"name":"dev-lead / b","status":"completed","conclusion":"success"}]},
    {"databaseId":2,"status":"completed","createdAt":"t2","jobs":[{"name":"dev-lead","status":"completed","conclusion":"skipped"},{"name":"pr-review-mention","status":"completed","conclusion":"success"}]},
    {"databaseId":3,"status":"completed","createdAt":"t3","jobs":[{"name":"dev-lead-ci","status":"completed","conclusion":"failure"}]}
  ]'
  [ "$status" -eq 0 ]
  [ "$output" = "[1]" ]
}

@test "agent_ingress_role_runs: role status/conclusion aggregate the role's own jobs (worst outcome)" {
  run bash -c 'source "$1"; agent_ingress_role_runs dev-lead <<<"$2" | jq -c "map({databaseId,status,conclusion,createdAt})"' _ "$INGRESS_LIB" '[
    {"databaseId":1,"status":"in_progress","createdAt":"t1","jobs":[{"name":"dev-lead / a","status":"queued","conclusion":null},{"name":"dev-lead / b","status":"in_progress","conclusion":null}]},
    {"databaseId":2,"status":"completed","createdAt":"t2","jobs":[{"name":"dev-lead / a","status":"completed","conclusion":"success"},{"name":"dev-lead / b","status":"completed","conclusion":"failure"},{"name":"pr-review-mention","status":"completed","conclusion":"success"}]},
    {"databaseId":3,"status":"in_progress","createdAt":"t3","jobs":[{"name":"dev-lead","status":"queued","conclusion":null},{"name":"other","status":"in_progress","conclusion":null}]}
  ]'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"databaseId":1,"status":"in_progress","conclusion":null,"createdAt":"t1"},{"databaseId":2,"status":"completed","conclusion":"failure","createdAt":"t2"},{"databaseId":3,"status":"queued","conclusion":null,"createdAt":"t3"}]' ]
}

@test "agent_ingress_gh_error_kind: missing workflow / 404 is permanent; anything else is transient" {
  run bash -c 'source "$1"
    agent_ingress_gh_error_kind "could not find any workflows named dev-lead"
    agent_ingress_gh_error_kind "HTTP 404: Not Found (https://api.github.com/repos/o/r/actions/workflows/dev-lead.yml)"
    agent_ingress_gh_error_kind "HTTP 502: Bad Gateway"
    agent_ingress_gh_error_kind ""' _ "$INGRESS_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = $'missing\nmissing\ntransient\ntransient' ]
}

# ===========================================================================
# arl_count_concurrent_runs — library concurrency tally
# ===========================================================================

@test "concurrency: a collapsed repo contributes its in-flight ingress role jobs" {
  seed_collapsed _local   # dev-lead workflow absent → ingress fallback
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  # runs 101 (in_progress) + 103 (queued); 102 is pr-review-mention only, 104 done.
  [ "$output" = "2" ]
}

@test "concurrency: only in-flight ingress runs have their jobs fetched" {
  seed_collapsed _local
  run bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  run grep -q 'runs/104/jobs' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

@test "concurrency: 100+ ingress runs with fewer matching role runs than the limit terminates" {
  # Every run is in-flight but serves pr-review-mention only; the history holds
  # more than 100 runs yet fewer than the 1000 requested, so end-of-history must
  # be detected against the requested limit (not a fixed page size).
  local i runs="["
  for i in $(seq 1 150); do
    runs+="{\"databaseId\":$((1000 + i)),\"status\":\"in_progress\",\"conclusion\":\"\",\"createdAt\":\"2026-10-02T10:00:00Z\"},"
    jobs_fixture $((1000 + i)) '[{"name":"dev-lead","status":"completed","conclusion":"skipped"},{"name":"pr-review-mention","status":"in_progress","conclusion":null}]'
  done
  runs_fixture _local agent-ingress.yml "${runs%,}]"
  run --separate-stderr timeout 60 bash -c 'source "$1"; arl_count_concurrent_runs pr-review-mention' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "150" ]
}

@test "concurrency: a non-collapsed repo still counts its per-role workflow runs" {
  runs_fixture _local dev-lead '[{"status":"in_progress"},{"status":"queued"},{"status":"completed"}]'
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run grep -q 'agent-ingress' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

@test "concurrency: a transient failure still degrades to 0 with its existing warning" {
  # dev-lead.yml is permanently missing, then the ingress read fails transiently.
  transient_fixture _local agent-ingress.yml
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [[ "$stderr" == *"returned no data (treating concurrency as 0)"* ]]
}

@test "concurrency: an ingress that declares no role job is UNRESOLVED, not 0" {
  runs_fixture _local agent-ingress.yml '[{"databaseId":104,"status":"completed","conclusion":"success","createdAt":"2026-10-02T09:00:00Z"}]'
  jobs_fixture 104 '[{"name":"pr-review-mention","status":"completed","conclusion":"success"}]'
  printf 'jobs:\n  pr-review-mention:\n    uses: x\n' | base64 -w 0 >"$GH_FIX/ingress.b64"
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 3 ]
  [ "$output" = "unresolved" ]
}

@test "concurrency: every jobs read failing is transient (degrades to 0), not resolved-empty" {
  runs_fixture _local agent-ingress.yml '[{"databaseId":777,"status":"in_progress","conclusion":"","createdAt":"2026-10-02T09:00:00Z"}]'
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [[ "$stderr" == *"returned no data"* ]]
}

@test "agent_ingress_gh_error_kind: workflow-only mode keeps a bare repo 404 transient" {
  run bash -c 'source "$1"
    agent_ingress_gh_error_kind "HTTP 404: Not Found" workflow-only
    agent_ingress_gh_error_kind "could not find any workflows named x" workflow-only' _ "$INGRESS_LIB"
  [ "$output" = $'transient\nmissing' ]
}

@test "concurrency: a permanent missing workflow with no ingress does NOT read as 0" {
  # No fixture at all: dev-lead.yml AND agent-ingress.yml are both missing.
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 3 ]
  [ "$output" != "0" ]
  [ "$output" = "unresolved" ]
  [[ "$stderr" == *"UNRESOLVED"* ]]
}

@test "concurrency: AGENT_RATE_LIMITS_ORG_REPOS tallies a mixed collapsed/non-collapsed fleet" {
  runs_fixture _local dev-lead '[{"status":"in_progress"},{"status":"in_progress"}]'      # legacy: 2
  seed_collapsed petry-projects/markets                                                   # collapsed: 2
  runs_fixture petry-projects/other dev-lead '[{"status":"queued"},{"status":"completed"}]' # legacy: 1
  export AGENT_RATE_LIMITS_ORG_REPOS="petry-projects/markets, petry-projects/other"
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "concurrency: an unresolved OTHER org repo counts 0 with a warning (no org-wide wedge)" {
  runs_fixture _local dev-lead '[{"status":"in_progress"}]'
  export AGENT_RATE_LIMITS_ORG_REPOS="petry-projects/ghost"
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [[ "$stderr" == *"petry-projects/ghost"* ]]
}

@test "concurrency: the gated (current) repo unresolved still fails closed even with healthy org repos" {
  seed_collapsed petry-projects/markets
  export AGENT_RATE_LIMITS_ORG_REPOS="petry-projects/markets"
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 3 ]
  [ "$output" = "unresolved" ]
}

@test "concurrency: a permission-caused bare 404 on a private org repo is transient, not permanently missing" {
  runs_fixture _local dev-lead '[{"status":"in_progress"}]'
  : >"$GH_FIX/runs/petry-projects_private__dev-lead.forbidden"
  : >"$GH_FIX/runs/petry-projects_private__agent-ingress.yml.forbidden"
  export AGENT_RATE_LIMITS_ORG_REPOS="petry-projects/private"
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [[ "$stderr" == *"returned no data"* ]]
}

@test "resolve: inflight_only uses status-filtered listing and reads jobs only for in-flight runs of a large history" {
  local i runs="[" n=0
  for i in $(seq 1 300); do
    runs+="{\"databaseId\":$((2000 + i)),\"status\":\"completed\",\"conclusion\":\"success\",\"createdAt\":\"2026-10-02T10:00:00Z\"},"
  done
  runs+='{"databaseId":9001,"status":"in_progress","conclusion":"","createdAt":"2026-10-02T11:00:00Z"},{"databaseId":9002,"status":"queued","conclusion":"","createdAt":"2026-10-02T11:01:00Z"}]'
  runs_fixture _local agent-ingress.yml "$runs"
  jobs_fixture 9001 '[{"name":"dev-lead","status":"in_progress","conclusion":null}]'
  jobs_fixture 9002 '[{"name":"dev-lead","status":"queued","conclusion":null}]'
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  n="$(grep -c '/jobs' "$GH_STUB_LOG" || true)"
  [ "$n" -eq 2 ]
  grep -q -- '--status queued' "$GH_STUB_LOG"
  grep -q -- '--status in_progress' "$GH_STUB_LOG"
}

@test "resolve: history path caps total jobs reads and degrades loudly" {
  local i runs="[" n=0
  for i in $(seq 1 120); do
    runs+="{\"databaseId\":$((3000 + i)),\"status\":\"completed\",\"conclusion\":\"success\",\"createdAt\":\"2026-10-02T10:00:00Z\"},"
    jobs_fixture $((3000 + i)) '[{"name":"pr-review-mention","status":"completed","conclusion":"success"}]'
  done
  runs_fixture _local agent-ingress.yml "${runs%,}]"
  printf 'jobs:\n  dev-lead:\n    uses: x\n' | base64 -w 0 >"$GH_FIX/ingress.b64"
  export AGENT_INGRESS_MAX_JOBS_READS=25
  # A rare role (never present): without a cap this would scan all 120 runs.
  run --separate-stderr timeout 60 bash -c 'source "$1"; arl_resolve_agent_runs agent-ingress.yml dev-lead "" 10' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  n="$(grep -c '/jobs' "$GH_STUB_LOG" || true)"
  [ "$n" -le 25 ]
  [[ "$stderr" == *"jobs-read cap"* ]]
}

@test "concurrency: a transient repo in AGENT_RATE_LIMITS_ORG_REPOS degrades only that repo" {
  runs_fixture _local dev-lead '[{"status":"in_progress"}]'
  transient_fixture petry-projects/flaky dev-lead
  export AGENT_RATE_LIMITS_ORG_REPOS="petry-projects/flaky"
  run --separate-stderr bash -c 'source "$1"; arl_count_concurrent_runs dev-lead' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ===========================================================================
# arl_admission_gate — fails closed on unresolved, throttles a collapsed repo
# ===========================================================================

@test "library gate: a collapsed repo at its concurrency cap is deferred" {
  write_config dev-lead 2 0 0 3 30
  seed_collapsed _local
  run bash -c 'source "$1"; arl_admission_gate dev-lead someone' _ "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "library gate: unresolved concurrency fails closed (defer), not allow" {
  write_config dev-lead 5 0 0 3 30
  run bash -c 'source "$1"; arl_admission_gate dev-lead someone' _ "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"unresolved"* ]]
}

@test "library gate: a transient enumeration failure still allows (existing fail-open)" {
  write_config dev-lead 5 0 0 3 30
  transient_fixture _local dev-lead
  run bash -c 'source "$1"; arl_admission_gate dev-lead someone' _ "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# ===========================================================================
# agent-rate-limit-gate.sh — run-history resolution
# ===========================================================================

@test "orchestrator: a collapsed repo's history is derived from ingress role jobs" {
  write_config dev-lead 2 0 0 3 30
  seed_collapsed _local
  run --separate-stderr env SOURCE_NOW=1790000000 bash "$GATE" dev-lead --mode enforce --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"concurrent=2"* ]]
  [ "$output" = "decision=defer" ]
}

@test "orchestrator: the gate running inside agent-ingress.yml counts only its own role" {
  write_config dev-lead 3 0 0 3 30
  seed_collapsed _local
  run --separate-stderr env SOURCE_NOW=1790000000 bash "$GATE" dev-lead --mode enforce --workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # 3 in-flight ingress runs, but only 2 carry a live dev-lead job.
  [[ "$stderr" == *"concurrent=2"* ]]
  [ "$output" = "decision=allow" ]
}

@test "orchestrator: consecutive failures come from the role job's conclusion" {
  write_config dev-lead 9 0 0 3 600
  runs_fixture _local agent-ingress.yml '[
    {"databaseId":201,"status":"completed","conclusion":"failure","createdAt":"2026-10-02T10:00:00Z"},
    {"databaseId":202,"status":"completed","conclusion":"failure","createdAt":"2026-10-02T10:01:00Z"},
    {"databaseId":203,"status":"completed","conclusion":"failure","createdAt":"2026-10-02T10:02:00Z"},
    {"databaseId":204,"status":"completed","conclusion":"failure","createdAt":"2026-10-02T10:03:00Z"}
  ]'
  jobs_fixture 201 '[{"name":"dev-lead / run","status":"completed","conclusion":"failure"}]'
  jobs_fixture 202 '[{"name":"dev-lead / run","status":"completed","conclusion":"failure"}]'
  jobs_fixture 203 '[{"name":"dev-lead / run","status":"completed","conclusion":"failure"}]'
  # 204 failed only in a sibling role — must not count toward dev-lead's streak.
  jobs_fixture 204 '[{"name":"dev-lead","status":"completed","conclusion":"skipped"},{"name":"pr-review-mention","status":"completed","conclusion":"failure"}]'
  run --separate-stderr env SOURCE_NOW="$(date -u -d 2026-10-02T10:05:00Z +%s)" bash "$GATE" dev-lead --mode enforce --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"consecutive_failures=3"* ]]
  [ "$output" = "decision=defer" ]
}

@test "orchestrator: unresolved history (no workflow, no ingress) defers in enforce mode" {
  write_config dev-lead 5 0 0 3 30
  run --separate-stderr env SOURCE_NOW=1790000000 bash "$GATE" dev-lead --mode enforce --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "decision=defer" ]
  [[ "$stderr" == *"UNRESOLVED"* ]]
}

@test "orchestrator: unresolved history in log-only mode logs defer but emits allow" {
  write_config dev-lead 5 0 0 3 30
  run --separate-stderr env SOURCE_NOW=1790000000 bash "$GATE" dev-lead --mode log-only --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "decision=allow" ]
  [[ "$stderr" == *"computed decision=defer"* ]]
}

@test "orchestrator: a transient history failure still degrades to allow with its warning" {
  write_config dev-lead 5 0 0 3 30
  transient_fixture _local dev-lead.yml
  run --separate-stderr env SOURCE_NOW=1790000000 bash "$GATE" dev-lead --mode enforce --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "decision=allow" ]
  [[ "$stderr" == *"treating as empty (degraded)"* ]]
}
