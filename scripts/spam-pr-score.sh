#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/spam-pr-score.sh — deterministic, metadata-only spam-PR scorer
# (epic #1200 spam-pr-guard, story #1203; signal table per discussion #1198).
#
# Scores an outside pull request from METADATA ONLY — title, body, diffstat and
# patch text from the API, author_association, account age, head branch, and an
# org-wide open-PR burst count. It never checks out or executes PR code and
# never invokes an LLM (contrast scripts/stale-manager.sh). Every weight,
# threshold, the burst limit N and the security-sensitive path list are DATA in
# standards/spam-pr-guard.json; nothing numeric is hardcoded here.
#
# Shape (AGENTS.md "Decision Logic Lives in a Pure, Tested Script"):
#   sps_score <facts.json> [config]   PURE core: no network, no clock, no
#                                     checkout. The current time arrives as the
#                                     `now` fact, so identical inputs always give
#                                     identical output.
#   sps_gather_facts <repo> <pr>      thin `gh api` glue that builds the facts doc.
#
# Facts document (JSON object) — the core's only input:
#   Gate facts (always required):
#     author_association  string   e.g. NONE, FIRST_TIME_CONTRIBUTOR, MEMBER
#     author_type         string   GitHub user type; "Bot" is always exempt
#     is_fork             boolean  head repo differs from base repo
#   Scoring facts (required only when the PR is scored):
#     title               string
#     body                string|null  (null = an empty body, GitHub's encoding)
#     head_ref            string
#     head_repo_default_branch string
#     author_created_at   string   ISO-8601 UTC, e.g. 2026-11-17T09:00:00Z
#     author_followers    integer >= 0
#     author_public_repos integer >= 0
#     files               non-empty array of {path, additions, deletions, patch}
#                         (patch: string, or null when GitHub has no text diff)
#     org_open_prs_24h    integer >= 0  open PRs the author created org-wide in
#                                       the 24h before `now`
#     now                 string   ISO-8601 UTC
#
# Output (stdout, one key=value per line, fixed order):
#   scored=true|false
#   exempt_reason=<bot|association:X|>         set only when scored=false
#   raw_score=<int>                            raw points total (0 when exempt)
#   level=low|medium|high                      raw_score vs config thresholds
#   escalate=true|false
#   escalate_reason=<security-sensitive-path:PATH|>
#   auto_close_eligible=true|false             high AND not escalated
#   signals=<comma-separated fired signals>
#
# Fail-closed (story #1203 AC5): if the config or any required fact cannot be
# read, is missing, or has the wrong type — or a signal helper or gh call fails —
# the script prints a FAIL-CLOSED reason on stderr, emits NO verdict, and exits
# 2. The caller (the Phase 3 reusable) must escalate to a human, never treat the
# PR as "not spam". Usage errors exit 64.
#
# Usage:
#   spam-pr-score.sh --facts <file|->       [--config <file>]
#   spam-pr-score.sh --repo <owner/repo> --pr <number> [--config <file>]
#
# Env: SPS_NOW — ISO-8601 UTC override of the clock for the gh glue (tests).
#
# Burst-signal credential: the org-wide count comes from the Search API. The
# default GITHUB_TOKEN is sufficient for public repos; private-repo visibility
# needs an explicitly declared, named token (see story #1203 Dev Notes).

SPS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPS_REPO_ROOT="$(cd "$SPS_SCRIPT_DIR/.." && pwd)"
SPS_DEFAULT_CONFIG="$SPS_REPO_ROOT/standards/spam-pr-guard.json"

# The empty-template signal is the Phase 1 helper — one source of truth for
# description parsing (story #1203 AC3).
# shellcheck source=scripts/lib/safety-checks.sh
source "$SPS_SCRIPT_DIR/lib/safety-checks.sh"

SPS_EXIT_FAIL_CLOSED=2
SPS_EXIT_USAGE=64

# Signals in their fixed reporting order; each key is also a config weight key.
SPS_SIGNAL_KEYS=(
  empty_template
  bare_title
  small_doc_diff_no_issue
  typo_introduced
  fork_default_branch
  new_account_no_activity
  burst
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_sps_fail() {
  echo "spam-pr-score: FAIL-CLOSED: $*" >&2
  return "$SPS_EXIT_FAIL_CLOSED"
}

# _sps_get <json> <path-filter> <kind> — print one typed value or fail closed.
# kind: string | nullable-string | bool | int (non-negative integer <= 1000000,
# so sums of weights can never overflow Bash arithmetic).
_sps_get() {
  local json="$1" path="$2" kind="$3" check
  case "$kind" in
    string)          check='type == "string"' ;;
    nullable-string) check='type == "string" or . == null' ;;
    bool)            check='type == "boolean"' ;;
    int)             check='type == "number" and . >= 0 and . <= 1000000 and . == floor' ;;
    *) _sps_fail "internal: unknown kind '$kind'"; return ;;
  esac
  # Walk to the parent object and require the final key to be PRESENT, so a
  # missing key fails even for nullable-string (where a present null is valid).
  local out
  if ! out="$(jq -er --arg p "$path" "
      (\$p | ltrimstr(\".\") | split(\".\")) as \$ks
      | (if (\$ks | length) > 1 then getpath(\$ks[:-1]) else . end)
      | if type == \"object\" and has(\$ks[-1]) then .[\$ks[-1]] else error(\"missing\") end
      | if ($check) then (if . == null then \"\" else tostring end) else error(\"bad type\") end
    " <<<"$json" 2>/dev/null)"; then
    _sps_fail "required value '$path' is missing or not a valid $kind"
    return
  fi
  printf '%s' "$out"
}

# _sps_list <json> <path> — print a string array one element per line, or fail.
_sps_list() {
  local json="$1" path="$2" out
  if ! out="$(jq -er "($path) | if type == \"array\" and all(.[]; type == \"string\" and (test(\"\\n\") | not)) then (.[]) , \"\" else error(\"bad\") end" <<<"$json" 2>/dev/null)"; then
    _sps_fail "config list '$path' is missing or not an array of strings"
    return
  fi
  printf '%s' "$out"
}

# _sps_load_array <name> <lines> — split newline-separated text into an array
# (an empty text yields an empty array, not one empty element).
_sps_load_array() {
  local -n _sps_load_arr="$1"
  _sps_load_arr=()
  local _sps_load_line
  while IFS= read -r _sps_load_line; do
    [[ -n "$_sps_load_line" ]] && _sps_load_arr+=("$_sps_load_line")
  done <<<"$2"
  return 0
}

_sps_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# _sps_glob_match <path> <patterns...> — print the first matching pattern.
# Patterns are bash globs where `*` also matches `/`. Case-sensitive.
_sps_glob_match() {
  local path="$1" pat
  shift
  for pat in "$@"; do
    # shellcheck disable=SC2053  # unquoted RHS is the intended glob match
    if [[ "$path" == $pat ]]; then
      printf '%s' "$pat"
      return 0
    fi
  done
  return 1
}

# _sps_ere_any <subject> <patterns...> — true iff any ERE matches,
# case-insensitively.
_sps_ere_any() {
  local subject="$1" pat rc=1 restore
  shift
  restore="$(shopt -p nocasematch)"
  shopt -s nocasematch
  for pat in "$@"; do
    [[ "$subject" =~ $pat ]]
    case $? in
      0) rc=0; break ;;
      1) ;;
      *) rc=2; break ;;
    esac
  done
  eval "$restore"
  return "$rc"
}

# _sps_strip_html_comments — remove <!-- ... --> spans (template help text)
# from a body so references inside them do not count as linked issues.
_sps_strip_html_comments() {
  # Terminated spans first (non-greedy), then an unterminated `<!--` drops the
  # rest of the body. If jq fails, fail closed via empty output + status.
  # The body goes through stdin (raw-slurp), never argv: a large description
  # would otherwise exceed the kernel's per-argument limit ("Argument list too
  # long").
  printf '%s' "$1" | jq -Rsr 'gsub("(?s)<!--.*?-->"; "") | gsub("(?s)<!--.*$"; "")'
}

_sps_epoch() {
  local ts="$1" name="$2" out
  if ! out="$(jq -nr --arg t "$ts" '$t | fromdateiso8601' 2>/dev/null)"; then
    _sps_fail "'$name' is not an ISO-8601 UTC timestamp: '$ts'"
    return
  fi
  printf '%s' "$out"
}

# _sps_typo_introduced <patch> <typo words...> — true iff an added line holds a
# listed misspelling (whole word, case-insensitive) that no removed line holds.
_sps_typo_introduced() {
  local patch="$1" added="" removed="" line word re
  shift
  while IFS= read -r line; do
    case "$line" in
      '+++'*|'---'*) ;;
      '+'*) added+="${line:1}"$'\n' ;;
      '-'*) removed+="${line:1}"$'\n' ;;
    esac
  done <<<"$patch"
  added="${added,,}"
  removed="${removed,,}"
  for word in "$@"; do
    re="(^|[^[:alnum:]_])${word,,}([^[:alnum:]_]|$)"
    if [[ "$added" =~ $re ]] && ! [[ "$removed" =~ $re ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Gate (story #1203 AC2)
# ---------------------------------------------------------------------------

# sps_gate <author_type> <association> <is_fork> <config-json> — print
# "scored" or an exempt reason (bot | association:X).
sps_gate() {
  local type="$1" assoc="$2" is_fork="$3" config="$4" text
  local -a scored_assoc exempt_assoc
  text="$(_sps_list "$config" '.associations.scored')" || return
  _sps_load_array scored_assoc "$text"
  text="$(_sps_list "$config" '.associations.exempt')" || return
  _sps_load_array exempt_assoc "$text"

  if [[ "$type" == "Bot" ]]; then
    printf 'bot'
  elif _sps_in_list "$assoc" "${exempt_assoc[@]}"; then
    printf 'association:%s' "$assoc"
  elif _sps_in_list "$assoc" "${scored_assoc[@]}" || [[ "$is_fork" == "true" ]]; then
    printf 'scored'
  else
    printf 'association:%s' "$assoc"
  fi
}

# ---------------------------------------------------------------------------
# Pure scoring core
# ---------------------------------------------------------------------------

# sps_score <facts-file|-> [config-file] — print the verdict lines, or fail
# closed (exit status 2, no stdout).
sps_score() {
  local facts_file="$1" config_file="${2:-$SPS_DEFAULT_CONFIG}"
  local facts config

  command -v jq >/dev/null 2>&1 || { _sps_fail "jq is required"; return; }

  if [[ "$facts_file" == "-" ]]; then
    facts="$(cat)" || { _sps_fail "cannot read facts from stdin"; return; }
  else
    facts="$(cat -- "$facts_file" 2>/dev/null)" || { _sps_fail "cannot read facts file '$facts_file'"; return; }
  fi
  config="$(cat -- "$config_file" 2>/dev/null)" || { _sps_fail "cannot read config '$config_file'"; return; }
  jq -e 'type == "object"' <<<"$facts" >/dev/null 2>&1 || { _sps_fail "facts are not a JSON object"; return; }
  jq -e 'type == "object"' <<<"$config" >/dev/null 2>&1 || { _sps_fail "config '$config_file' is not a JSON object"; return; }

  # --- config (validated in full on every run, exempt or not) ---------------
  local medium high key text
  medium="$(_sps_get "$config" '.thresholds.medium' int)" || return
  high="$(_sps_get "$config" '.thresholds.high' int)" || return
  (( medium <= high )) || { _sps_fail "config thresholds.medium ($medium) exceeds thresholds.high ($high)"; return; }
  local -A weight=()
  for key in "${SPS_SIGNAL_KEYS[@]}"; do
    weight[$key]="$(_sps_get "$config" ".weights.$key" int)" || return
  done
  local min_missing burst_limit new_days max_repos max_followers small_max
  min_missing="$(_sps_get "$config" '.signals.empty_template_min_missing' int)" || return
  burst_limit="$(_sps_get "$config" '.signals.burst_limit' int)" || return
  new_days="$(_sps_get "$config" '.signals.new_account_days' int)" || return
  max_repos="$(_sps_get "$config" '.signals.no_activity_max_public_repos' int)" || return
  max_followers="$(_sps_get "$config" '.signals.no_activity_max_followers' int)" || return
  small_max="$(_sps_get "$config" '.signals.small_doc_diff_max_lines' int)" || return
  local -a title_pats doc_paths issue_pats typo_words sec_paths
  text="$(_sps_list "$config" '.bare_title_patterns')" || return
  _sps_load_array title_pats "$text"
  text="$(_sps_list "$config" '.doc_paths')" || return
  _sps_load_array doc_paths "$text"
  text="$(_sps_list "$config" '.linked_issue_patterns')" || return
  _sps_load_array issue_pats "$text"
  text="$(_sps_list "$config" '.typo_words')" || return
  _sps_load_array typo_words "$text"
  local tw
  for tw in "${typo_words[@]}"; do
    [[ "$tw" =~ ^[[:alnum:]_-]+$ ]] || { _sps_fail "config typo_words entry '$tw' is not a plain word"; return; }
  done
  text="$(_sps_list "$config" '.security_sensitive_paths')" || return
  _sps_load_array sec_paths "$text"
  local pat re_rc
  for pat in "${title_pats[@]}" "${issue_pats[@]}"; do
    # Errexit-safe: capture invalid-regex exit status (2) with || operator,
    # which prevents 'set -e' in a caller from terminating on the [[ ]] result.
    re_rc=0
    # shellcheck disable=SC2319  # $? is the [[ =~ ]] status (2 = invalid regex), intentionally
    [[ "" =~ $pat ]] || re_rc=$?
    (( re_rc != 2 )) || { _sps_fail "config contains an invalid regular expression: '$pat'"; return; }
  done

  # --- gate ------------------------------------------------------------------
  local assoc author_type is_fork gate
  assoc="$(_sps_get "$facts" '.author_association' string)" || return
  [[ -n "$assoc" ]] || { _sps_fail "author_association is empty"; return; }
  author_type="$(_sps_get "$facts" '.author_type' string)" || return
  is_fork="$(_sps_get "$facts" '.is_fork' bool)" || return
  gate="$(sps_gate "$author_type" "$assoc" "$is_fork" "$config")" || return
  if [[ "$gate" != "scored" ]]; then
    printf '%s\n' "scored=false" "exempt_reason=$gate" "raw_score=0" "level=low" \
      "escalate=false" "escalate_reason=" "auto_close_eligible=false" "signals="
    return 0
  fi

  # --- scoring facts -----------------------------------------------------------
  local title body head_ref head_default created now followers repos burst_count
  title="$(_sps_get "$facts" '.title' string)" || return
  body="$(_sps_get "$facts" '.body' nullable-string)" || return
  head_ref="$(_sps_get "$facts" '.head_ref' string)" || return
  head_default="$(_sps_get "$facts" '.head_repo_default_branch' string)" || return
  created="$(_sps_get "$facts" '.author_created_at' string)" || return
  now="$(_sps_get "$facts" '.now' string)" || return
  followers="$(_sps_get "$facts" '.author_followers' int)" || return
  repos="$(_sps_get "$facts" '.author_public_repos' int)" || return
  burst_count="$(_sps_get "$facts" '.org_open_prs_24h' int)" || return
  local created_epoch now_epoch
  created_epoch="$(_sps_epoch "$created" author_created_at)" || return
  now_epoch="$(_sps_epoch "$now" now)" || return

  jq -e '.files | type == "array" and length > 0 and all(.[];
           type == "object"
           and (.path | type == "string" and length > 0 and (test("\n") | not))
           and (.additions | type == "number" and . >= 0 and . == floor)
           and (.deletions | type == "number" and . >= 0 and . == floor)
           and has("patch") and (.patch | type == "string" or . == null))' \
    <<<"$facts" >/dev/null 2>&1 \
    || { _sps_fail "'files' must be a non-empty array of {path, additions, deletions, patch}"; return; }
  local -a paths
  local nfiles total_add total_del
  _sps_load_array paths "$(jq -r '.files[].path' <<<"$facts")"
  nfiles="$(jq -r '.files | length' <<<"$facts")"
  total_add="$(jq -r '[.files[].additions] | add' <<<"$facts")"
  total_del="$(jq -r '[.files[].deletions] | add' <<<"$facts")"
  (( ${#paths[@]} == nfiles )) || { _sps_fail "could not read every file path"; return; }

  # --- signals -----------------------------------------------------------------
  local -A fired=()

  # Empty template: the Phase 1 helper's integer, as a 0/1 indicator × weight.
  local missing
  if ! missing="$(printf '%s' "$body" | sc_description_missing)" || ! [[ "$missing" =~ ^[0-9]+$ ]]; then
    _sps_fail "sc_description_missing could not score the PR body"
    return
  fi
  (( missing >= min_missing )) && fired[empty_template]=1

  local trimmed="${title#"${title%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  _sps_ere_any "$trimmed" "${title_pats[@]}" && fired[bare_title]=1

  local all_docs=1 p
  for p in "${paths[@]}"; do
    _sps_glob_match "$p" "${doc_paths[@]}" >/dev/null || { all_docs=0; break; }
  done
  local changed=$(( total_add > total_del ? total_add : total_del ))
  local visible_body
  visible_body="$(_sps_strip_html_comments "$body")" \
    || { _sps_fail "could not strip HTML comments from the PR body"; return; }
  if (( all_docs && changed <= small_max )) \
    && ! _sps_ere_any "$visible_body" "${issue_pats[@]}"; then
    fired[small_doc_diff_no_issue]=1
  fi

  local i patch
  for (( i = 0; i < nfiles; i++ )); do
    patch="$(jq -r --argjson i "$i" '.files[$i].patch // ""' <<<"$facts")"
    if [[ -n "$patch" ]] && _sps_typo_introduced "$patch" "${typo_words[@]}"; then
      fired[typo_introduced]=1
      break
    fi
  done

  [[ "$is_fork" == "true" && "$head_ref" == "$head_default" ]] && fired[fork_default_branch]=1

  local age_days=$(( (now_epoch - created_epoch) / 86400 ))
  if (( age_days < new_days && repos <= max_repos && followers <= max_followers )); then
    fired[new_account_no_activity]=1
  fi

  (( burst_count > burst_limit )) && fired[burst]=1

  # --- total, level, escalation ------------------------------------------------
  local raw=0 signals=""
  for key in "${SPS_SIGNAL_KEYS[@]}"; do
    if [[ -n "${fired[$key]:-}" ]]; then
      raw=$(( raw + weight[$key] ))
      signals+="${signals:+,}$key"
    fi
  done
  local level=low
  if (( raw >= high )); then level=high; elif (( raw >= medium )); then level=medium; fi

  local escalate=false reason=""
  local -a prev_paths
  _sps_load_array prev_paths "$(jq -r '.files[] | (.previous_filename // empty | select(type == "string"))' <<<"$facts")"
  for p in "${paths[@]}" "${prev_paths[@]}"; do
    if _sps_glob_match "$p" "${sec_paths[@]}" >/dev/null; then
      escalate=true
      reason="security-sensitive-path:$p"
      break
    fi
  done
  local auto_close=false
  [[ "$level" == "high" && "$escalate" == "false" ]] && auto_close=true

  printf '%s\n' "scored=true" "exempt_reason=" "raw_score=$raw" "level=$level" \
    "escalate=$escalate" "escalate_reason=$reason" "auto_close_eligible=$auto_close" \
    "signals=$signals"
}

# ---------------------------------------------------------------------------
# gh glue — gathers the facts document (metadata API calls only, no checkout)
# ---------------------------------------------------------------------------

# sps_gather_facts <owner/repo> <pr-number> [config-file] — print the facts JSON.
# Exempt authors (bots, members, ...) get only the gate facts, so a bot PR never
# fails closed on an API call it does not need.
sps_gather_facts() {
  local repo="$1" pr="$2" config_file="${3:-$SPS_DEFAULT_CONFIG}"
  local now="${SPS_NOW:-}" pr_json config gate_facts gate
  [[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  config="$(cat -- "$config_file" 2>/dev/null)" || { _sps_fail "cannot read config '$config_file'"; return; }

  pr_json="$(gh api "repos/$repo/pulls/$pr")" || { _sps_fail "gh: cannot read PR $repo#$pr"; return; }
  gate_facts="$(jq -e '{
      author_association, author_type: .user.type,
      # a deleted head repo (null) counts as a fork so the gate cannot exempt it;
      # the unavailable-head check below then fails closed.
      is_fork: (.head.repo == null or .head.repo.full_name != .base.repo.full_name)
    }' <<<"$pr_json" 2>/dev/null)" || { _sps_fail "cannot parse PR $repo#$pr"; return; }
  gate="$(sps_gate "$(jq -r '.author_type // ""' <<<"$gate_facts")" \
                   "$(jq -r '.author_association // ""' <<<"$gate_facts")" \
                   "$(jq -r '.is_fork' <<<"$gate_facts")" "$config")" || return
  if [[ "$gate" != "scored" ]]; then
    printf '%s\n' "$gate_facts"
    return 0
  fi

  # A deleted head repo hides the fork/default-branch signal — fail closed.
  jq -e '.head.repo != null' <<<"$pr_json" >/dev/null \
    || { _sps_fail "head repository of $repo#$pr is unavailable"; return; }

  local login user_json files_json since search_json
  login="$(jq -er '.user.login' <<<"$pr_json")" || { _sps_fail "PR author login missing"; return; }
  user_json="$(gh api "users/$login")" || { _sps_fail "gh: cannot read user $login"; return; }
  files_json="$(gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100")" \
    || { _sps_fail "gh: cannot read files of $repo#$pr"; return; }
  files_json="$(jq -s 'add | map({path: .filename, additions, deletions, patch: (.patch // null)}
        + (if (.previous_filename | type) == "string" then {previous_filename} else {} end))' <<<"$files_json")" \
    || { _sps_fail "cannot parse files of $repo#$pr"; return; }
  # The files endpoint caps at 3,000 entries; an incomplete inventory could hide
  # a security-sensitive path, so require it to match the PR's changed_files.
  jq -e --argjson n "$(jq -r '.changed_files' <<<"$pr_json")" 'length == $n' <<<"$files_json" >/dev/null 2>&1 \
    || { _sps_fail "file inventory of $repo#$pr is incomplete (changed_files mismatch)"; return; }
  since="$(jq -nr --arg now "$now" '$now | fromdateiso8601 - 86400 | todate')" \
    || { _sps_fail "invalid SPS_NOW '$now'"; return; }
  search_json="$(gh api -X GET search/issues \
      -f q="is:pr is:open author:$login org:${repo%%/*} created:>=$since" \
      -f per_page=1)" || { _sps_fail "gh: burst search failed for $login"; return; }
  jq -e '.incomplete_results == false and (.total_count | type == "number")' <<<"$search_json" >/dev/null \
    || { _sps_fail "burst search for $login returned incomplete results"; return; }

  # Large documents (patches) travel via temp files, never argv (ARG_MAX).
  local tmp
  tmp="$(mktemp -d)" || { _sps_fail "cannot create temp dir"; return; }
  printf '%s' "$pr_json" >"$tmp/pr.json"
  printf '%s' "$user_json" >"$tmp/user.json"
  printf '%s' "$files_json" >"$tmp/files.json"
  printf '%s' "$search_json" >"$tmp/search.json"
  printf '%s' "$gate_facts" >"$tmp/gate.json"
  local assembled rc=0
  assembled="$(jq -n --slurpfile pr "$tmp/pr.json" --slurpfile user "$tmp/user.json" \
        --slurpfile files "$tmp/files.json" --slurpfile search "$tmp/search.json" \
        --slurpfile gate "$tmp/gate.json" --arg now "$now" '
    $pr[0] as $pr | $user[0] as $user | $search[0] as $search |
    $gate[0] + {
      title: $pr.title,
      body: $pr.body,
      head_ref: $pr.head.ref,
      head_repo_default_branch: $pr.head.repo.default_branch,
      author_created_at: $user.created_at,
      author_followers: $user.followers,
      author_public_repos: $user.public_repos,
      files: $files[0],
      org_open_prs_24h: $search.total_count,
      now: $now
    }')" || rc=$?
  rm -rf "$tmp"
  (( rc == 0 )) || { _sps_fail "cannot assemble facts for $repo#$pr"; return; }
  printf '%s\n' "$assembled"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

_sps_usage() {
  sed -n '/^# Usage:/,/^# Env:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
  return "$SPS_EXIT_USAGE"
}

sps_main() {
  local facts="" repo="" pr="" config="$SPS_DEFAULT_CONFIG"
  while (( $# > 0 )); do
    case "$1" in
      --facts)  [[ $# -ge 2 ]] || { _sps_usage; return; }; facts="$2"; shift 2 ;;
      --repo)   [[ $# -ge 2 ]] || { _sps_usage; return; }; repo="$2"; shift 2 ;;
      --pr)     [[ $# -ge 2 ]] || { _sps_usage; return; }; pr="$2"; shift 2 ;;
      --config) [[ $# -ge 2 ]] || { _sps_usage; return; }; config="$2"; shift 2 ;;
      -h|--help) _sps_usage; return 0 ;;
      *) echo "spam-pr-score: unknown argument '$1'" >&2; _sps_usage; return ;;
    esac
  done

  if [[ -n "$facts" && -z "$repo$pr" ]]; then
    sps_score "$facts" "$config"
  elif [[ -z "$facts" && "$repo" == */* && "$pr" =~ ^[0-9]+$ ]]; then
    local gathered
    gathered="$(sps_gather_facts "$repo" "$pr" "$config")" || return
    sps_score - "$config" <<<"$gathered"
  else
    _sps_usage
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  sps_main "$@"
  exit $?
fi
