#!/usr/bin/env bats
# Integration tests for scripts/dismiss-stale-bot-reviews.sh — the thin I/O glue
# (#1115). They exercise the WHOLE path (GraphQL reads → pure core → dismissal
# mutation) with a fake `gh` that behaves like the real one: it exits NON-ZERO on
# failure (the real `gh api graphql` does on an errors envelope).
#
# Fixture PR (mirrors #1094): head is 8e5bc8db; an allow-listed bot's
# CHANGES_REQUESTED sits on the superseded aca48dc4 and MUST be dismissed, while
# a same-bot review on the current head, a human review, and a bot APPROVE must
# all be left alone. Bot logins use the GraphQL form (`coderabbitai`, no [bot]).
#
# Fake gh response files live in $D. For a call of kind K (reviews, threads,
# recheck, sweep) with PR number N and cursor C it serves the first existing of
#   K.prN.C.json  K.prN.json  K.C.json  K.json
# A file K.fail makes that kind exit 1. Mutations log `DISMISS <id>` to $GH_LOG;
# fail.<id> makes that mutation exit 1, envelope.<id> returns an errors envelope.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
ORCH="${REPO_ROOT}/scripts/dismiss-stale-bot-reviews.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  TT_TMP="$(mktemp -d)"
  D="${TT_TMP}/d"; mkdir -p "$D"; export D
  GH_LOG="${TT_TMP}/gh.log"; export GH_LOG; : > "$GH_LOG"
  DSBR_RETRY_UNIT=0; export DSBR_RETRY_UNIT
  cat > "$D/reviews.json" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "headRefOid":"8e5bc8db",
  "latestOpinionatedReviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"id":"PRR_stale","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai","__typename":"Bot"}},
    {"id":"PRR_human","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"don-petry","__typename":"User"}},
    {"id":"PRR_approved","state":"APPROVED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai","__typename":"Bot"}}
  ]}
}}}}
JSON
  cat > "$D/threads.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}
JSON
  echo '{"data":{"repository":{"pullRequest":{"headRefOid":"8e5bc8db"}}}}' > "$D/recheck.json"
  local bin="${TT_TMP}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
num="" cur=""
for a in "$@"; do
  case "$a" in number=*) num="${a#number=}" ;; cursor=*) cur="${a#cursor=}" ;; esac
done
[ "$cur" = "null" ] && cur=""
if [[ "$all" == *dismissPullRequestReview* ]]; then
  id=""
  for a in "$@"; do case "$a" in id=*) id="${a#id=}" ;; esac; done
  printf 'DISMISS %s\n' "$id" >> "$GH_LOG"
  if [ -e "$D/fail.$id" ]; then echo 'GraphQL: mutation failed' >&2; exit 1; fi
  if [ -e "$D/envelope.$id" ]; then printf '{"errors":[{"message":"review already dismissed"}]}'; exit 0; fi
  printf '{"data":{"dismissPullRequestReview":{"pullRequestReview":{"id":"x","state":"DISMISSED"}}}}'
  exit 0
fi
if   [[ "$all" == *reviewThreads* ]]; then kind=threads
elif [[ "$all" == *latestOpinionatedReviews* ]]; then kind=reviews
elif [[ "$all" == *reviewDecision* ]]; then kind=sweep
else kind=recheck; fi
printf 'READ %s pr=%s cursor=%s\n' "$kind" "$num" "$cur" >> "$GH_LOG"
if [ -e "$D/$kind.fail.pr$num" ] || [ -e "$D/$kind.fail" ]; then echo 'gh: failed' >&2; exit 1; fi
# Label fixtures (reviews and recheck responses only). The label list is injected
# into a response that has no `labels` key, so older fixtures stay valid:
#   reviews: labels.prN.json, labels.json
#   recheck: labels.recheck.prN.json, labels.recheck.<call#>.json, labels.recheck.json
# default is an empty, readable list. labels.missing.<kind> leaves the key out;
# malformed.<kind>[.prN] serves a body that is not JSON.
default_labels='{"pageInfo":{"hasNextPage":false},"nodes":[]}'
serve() {
  if [ -e "$D/malformed.$kind.pr$num" ] || [ -e "$D/malformed.$kind" ]; then echo 'not json{'; exit 0; fi
  if [ "$kind" = reviews ] || [ "$kind" = recheck ]; then
    lf=""
    if [ "$kind" = recheck ]; then
      n=$(( $(cat "$D/recheck.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/recheck.count"
      cands=("labels.recheck.pr$num.json" "labels.recheck.$n.json" "labels.recheck.json")
    else
      cands=("labels.pr$num.json" "labels.json")
    fi
    for c in "${cands[@]}"; do [ -e "$D/$c" ] && { lf="$D/$c"; break; }; done
    L="$default_labels"; [ -z "$lf" ] || L="$(cat "$lf")"
    if [ -e "$D/labels.missing.$kind" ]; then cat "$1"; exit 0; fi
    jq -c --argjson L "$L" 'if (.data.repository.pullRequest | type == "object") and (.data.repository.pullRequest | has("labels") | not) then .data.repository.pullRequest.labels = $L else . end' "$1"
    exit 0
  fi
  cat "$1"
}
for f in "$kind.pr$num.$cur.json" "$kind.pr$num.json" "$kind.$cur.json" "$kind.json"; do
  [ -n "$cur" ] || case "$f" in *..json) continue ;; esac
  if [ -e "$D/$f" ]; then serve "$D/$f"; exit 0; fi
done
echo "fake gh: no fixture for $kind pr=$num cursor=$cur" >&2; exit 1
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

teardown() { rm -rf "${TT_TMP:-/nonexistent}"; }

dismissed() { grep '^DISMISS ' "$GH_LOG" | sort | tr '\n' ' '; }

@test "dismisses ONLY the stale allow-listed bot review; leaves head/human/approved" {
  # add a same-bot review on the CURRENT head: must be kept
  jq '.data.repository.pullRequest.latestOpinionatedReviews.nodes += [{"id":"PRR_head","state":"CHANGES_REQUESTED","commit":{"oid":"8e5bc8db"},"author":{"login":"coderabbitai","__typename":"Bot"}}]' \
    "$D/reviews.json" > "$D/r.tmp" && mv "$D/r.tmp" "$D/reviews.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'dismissed 1 stale bot review'
  [ "$(dismissed)" = "DISMISS PRR_stale " ]
}

@test "the [bot]-suffixed login form is also dismissed" {
  sed -i 's/"coderabbitai"/"coderabbitai[bot]"/' "$D/reviews.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale " ]
}

@test "a User whose login is coderabbitai is kept" {
  sed -i 's/"login":"coderabbitai","__typename":"Bot"/"login":"coderabbitai","__typename":"User"/' "$D/reviews.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ -z "$(dismissed)" ]
}

@test "dry-run examines but dismisses nothing (no mutation)" {
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[dry-run\] would dismiss review PRR_stale'
  echo "$output" | grep -q 'would dismiss 1 stale bot review'
  echo "$output" | grep -q 'no reviews were dismissed'
  [ -z "$(dismissed)" ]
}

@test "queries latestOpinionatedReviews, never latestReviews" {
  local qlog="${TT_TMP}/query.log"
  mv "${TT_TMP}/bin/gh" "${TT_TMP}/bin/gh.real"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s"\nexec "%s/bin/gh.real" "$@"\n' "$qlog" "$TT_TMP" > "${TT_TMP}/bin/gh"
  chmod +x "${TT_TMP}/bin/gh"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094
  [ "$status" -eq 0 ]
  grep -q 'latestOpinionatedReviews' "$qlog"
  run grep -qE 'latestReviews\b' "$qlog"
  [ "$status" -eq 1 ]
}

@test "pages reviews: dismisses a stale bot review found only on page 2" {
  cat > "$D/reviews.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"headRefOid":"8e5bc8db","latestOpinionatedReviews":{
  "pageInfo":{"hasNextPage":true,"endCursor":"CURSOR2"},"nodes":[
  {"id":"PRR_head_p1","state":"CHANGES_REQUESTED","commit":{"oid":"8e5bc8db"},"author":{"login":"coderabbitai","__typename":"Bot"}}]}}}}}
JSON
  cat > "$D/reviews.CURSOR2.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"headRefOid":"8e5bc8db","latestOpinionatedReviews":{
  "pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRR_stale_p2","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai","__typename":"Bot"}}]}}}}}
JSON
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'examined 2 effective review(s), dismissed 1 stale bot review'
  [ "$(dismissed)" = "DISMISS PRR_stale_p2 " ]
}

@test "a non-advancing pagination cursor is an error, not an endless loop" {
  jq '.data.repository.pullRequest.latestOpinionatedReviews.pageInfo = {"hasNextPage":true,"endCursor":"CURSOR2"}' \
    "$D/reviews.json" > "$D/reviews.json.tmp" && mv "$D/reviews.json.tmp" "$D/reviews.json"
  cp "$D/reviews.json" "$D/reviews.CURSOR2.json"
  run timeout 30 env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'non-advancing cursor'
  [ -z "$(dismissed)" ]
}

@test "an open current thread by the same bot keeps its review" {
  cat > "$D/threads.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}
JSON
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ -z "$(dismissed)" ]
}

@test "resolved, outdated and other-author threads do not keep the review" {
  cat > "$D/threads.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}},
  {"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}},
  {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"don-petry"}}]}}]}}}}}
JSON
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale " ]
}

@test "an open current thread on page 2 keeps the review" {
  cat > "$D/threads.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"TC2"},"nodes":[
  {"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}
JSON
  cat > "$D/threads.TC2.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"}}]}}]}}}}}
JSON
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ -z "$(dismissed)" ]
}

@test "a thread read error dismisses nothing and fails the run" {
  : > "$D/threads.fail"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'review threads'
  [ -z "$(dismissed)" ]
}

@test "a thread errors envelope dismisses nothing and fails the run" {
  echo '{"errors":[{"message":"rate limited"}]}' > "$D/threads.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  [ -z "$(dismissed)" ]
}

@test "no-op (exit 0) when the PR head really moves before the dismissal loop" {
  echo '{"data":{"repository":{"pullRequest":{"headRefOid":"deadbeef"}}}}' > "$D/recheck.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PR head moved from 8e5bc8db to deadbeef'
  [ -z "$(dismissed)" ]
}

@test "an unreadable head recheck is a failure, not a moved head" {
  : > "$D/recheck.fail"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  ! echo "$output" | grep -q 'head moved'
  [ -z "$(dismissed)" ]
}

@test "a head recheck errors envelope is a failure" {
  echo '{"errors":[{"message":"rate limited"}]}' > "$D/recheck.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'rechecking head'
  [ -z "$(dismissed)" ]
}

@test "a failed mutation does not stop the next candidate; the run exits non-zero" {
  jq '.data.repository.pullRequest.latestOpinionatedReviews.nodes = [
    {"id":"PRR_a","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai","__typename":"Bot"}},
    {"id":"PRR_b","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}}]' \
    "$D/reviews.json" > "$D/r.tmp" && mv "$D/r.tmp" "$D/reviews.json"
  : > "$D/fail.PRR_a"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '::error::dismissal of review PRR_a'
  echo "$output" | grep -q 'Dismissed stale review PRR_b'
  grep -qx 'DISMISS PRR_b' "$GH_LOG"
}

@test "a mutation errors envelope is counted as a failure, not a dismissal" {
  : > "$D/envelope.PRR_stale"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'returned a GraphQL errors envelope'
  echo "$output" | grep -q 'dismissed 0 stale bot review'
}

@test "requires --owner, --name and one of --pr / --sweep" {
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'required'
}

# ── --sweep ─────────────────────────────────────────────────────────────────

sweep_fixtures() {
  # page 1: #1 (not blocked), #2 (blocked). page 2: #3 (blocked), #4 (blocked, fails).
  cat > "$D/sweep.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":true,"endCursor":"SW2"},"nodes":[
  {"number":1,"reviewDecision":"APPROVED"},{"number":2,"reviewDecision":"CHANGES_REQUESTED"}]}}}}
JSON
  cat > "$D/sweep.SW2.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"number":3,"reviewDecision":"CHANGES_REQUESTED"},{"number":4,"reviewDecision":"CHANGES_REQUESTED"}]}}}}
JSON
  local n
  for n in 2 3 4; do
    sed "s/PRR_stale/PRR_stale_$n/; s/PRR_human/PRR_human_$n/; s/PRR_approved/PRR_approved_$n/" "$D/reviews.json" > "$D/reviews.pr$n.json"
  done
}

@test "sweep: dismisses on a second page of PRs and skips a PR not blocked by CHANGES_REQUESTED" {
  sweep_fixtures
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale_2 DISMISS PRR_stale_3 DISMISS PRR_stale_4 " ]
  # PR #1 (APPROVED) was never read
  ! grep -q 'pr=1 ' "$GH_LOG"
  echo "$output" | grep -q 'checked 4 open PR(s), 3 blocked by CHANGES_REQUESTED, 0 failed'
}

@test "sweep: keeps human and on-head reviews" {
  sweep_fixtures
  jq '.data.repository.pullRequest.latestOpinionatedReviews.nodes = [
    {"id":"H","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"don-petry","__typename":"User"}},
    {"id":"O","state":"CHANGES_REQUESTED","commit":{"oid":"8e5bc8db"},"author":{"login":"coderabbitai","__typename":"Bot"}}]' \
    "$D/reviews.json" > "$D/reviews.pr2.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
  [ "$status" -eq 0 ]
  ! grep -qE 'DISMISS (H|O)$' "$GH_LOG"
  grep -qx 'DISMISS PRR_stale_3' "$GH_LOG"
}

@test "sweep: continues after one PR fails and exits non-zero" {
  sweep_fixtures
  : > "$D/reviews.fail.pr2"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
  [ "$status" -eq 1 ]
  [ "$(dismissed)" = "DISMISS PRR_stale_3 DISMISS PRR_stale_4 " ]
  echo "$output" | grep -q '3 blocked by CHANGES_REQUESTED, 1 failed'
}

@test "sweep: dry-run dismisses nothing" {
  sweep_fixtures
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep
  [ "$status" -eq 0 ]
  [ -z "$(dismissed)" ]
}

@test "sweep: an unreadable PR list fails the run" {
  : > "$D/sweep.fail"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
  [ "$status" -eq 1 ]
}

# ---- hold labels (#1115): needs-human-review, dev-lead:needs-human, dev-lead:hands-off ----

HOLDS=(needs-human-review dev-lead:needs-human dev-lead:hands-off)

label_json() { # <name>... -> readable label list
  local out="" n
  for n in "$@"; do out+="${out:+,}{\"name\":\"$n\"}"; done
  printf '{"pageInfo":{"hasNextPage":false},"nodes":[%s]}' "$out"
}

# unreadable forms: each is "<tag>" understood by set_unreadable
FORMS=(envelope null missing nodes-missing nodes-null bad-name next-page next-missing pageinfo-missing malformed)

# set_unreadable <kind: reviews|recheck> <form> [pr]
set_unreadable() {
  local kind="$1" form="$2" pr="${3:-}" file suffix=""
  [ -z "$pr" ] || suffix=".pr$pr"
  if [ "$kind" = reviews ]; then file="$D/labels${suffix}.json"; else file="$D/labels.recheck${suffix}.json"; fi
  case "$form" in
    envelope)
      if [ "$kind" = reviews ]; then
        echo '{"errors":[{"message":"boom"}]}' > "$D/reviews${suffix}.json"
      else
        echo '{"errors":[{"message":"boom"}]}' > "$D/recheck${suffix}.json"
      fi ;;
    null) echo 'null' > "$file" ;;
    missing) : > "$D/labels.missing.$kind" ;;
    nodes-missing) echo '{"pageInfo":{"hasNextPage":false}}' > "$file" ;;
    nodes-null) echo '{"pageInfo":{"hasNextPage":false},"nodes":null}' > "$file" ;;
    bad-name) echo '{"pageInfo":{"hasNextPage":false},"nodes":[{"name":7}]}' > "$file" ;;
    next-page) echo '{"pageInfo":{"hasNextPage":true},"nodes":[]}' > "$file" ;;
    next-missing) echo '{"pageInfo":{},"nodes":[]}' > "$file" ;;
    pageinfo-missing) echo '{"nodes":[]}' > "$file" ;;
    malformed) : > "$D/malformed.$kind${suffix}" ;;
  esac
}

@test "hold label on --pr --apply: each of the three holds dismisses nothing and exits 0" {
  local h
  for h in "${HOLDS[@]}"; do
    : > "$GH_LOG"
    label_json size:L "$h" > "$D/labels.json"
    run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "::notice::.*combsmith/.github#1094 is held for a human by label '$h'"
    [ -z "$(dismissed)" ]
  done
}

@test "hold label match is case-insensitive" {
  label_json "Needs-Human-Review" > "$D/labels.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ -z "$(dismissed)" ]
}

@test "a label that is not a hold does not hold the PR" {
  label_json size:XL needs-human-review-later "dev-lead:needs-human-x" > "$D/labels.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale " ]
}

@test "hold label on --sweep --apply: held PR untouched, unheld PR still dismissed, held counted" {
  local h
  for h in "${HOLDS[@]}"; do
    : > "$GH_LOG"; rm -f "$D"/labels*.json
    sweep_fixtures
    label_json "$h" > "$D/labels.pr2.json"
    run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
    [ "$status" -eq 0 ]
    [ "$(dismissed)" = "DISMISS PRR_stale_3 DISMISS PRR_stale_4 " ]
    echo "$output" | grep -q "is held for a human by label '$h'"
    echo "$output" | grep -q '0 failed on combsmith/.github, 1 held by a label'
  done
}

@test "sweep: another label does not hold" {
  sweep_fixtures
  label_json size:XL > "$D/labels.pr2.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale_2 DISMISS PRR_stale_3 DISMISS PRR_stale_4 " ]
  echo "$output" | grep -q '0 failed on combsmith/.github, 0 held by a label'
}

@test "a hold label that appears only at the first recheck holds the PR" {
  label_json needs-human-review > "$D/labels.recheck.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'held for a human by label'
  [ -z "$(dismissed)" ]
}

@test "a hold label that appears between two candidates stops the remaining dismissals" {
  jq '.data.repository.pullRequest.latestOpinionatedReviews.nodes += [{"id":"PRR_stale2","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}}]' \
    "$D/reviews.json" > "$D/r.tmp" && mv "$D/r.tmp" "$D/reviews.json"
  # recheck calls: 1 = before the loop, 2 = first candidate, 3 = second candidate
  label_json dev-lead:hands-off > "$D/labels.recheck.3.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale " ]
  echo "$output" | grep -q "held for a human by label 'dev-lead:hands-off'"
}

@test "an earlier mutation failure survives a later hold label stopping the remaining dismissals" {
  jq '.data.repository.pullRequest.latestOpinionatedReviews.nodes += [{"id":"PRR_stale2","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}}]' \
    "$D/reviews.json" > "$D/r.tmp" && mv "$D/r.tmp" "$D/reviews.json"
  : > "$D/envelope.PRR_stale"
  label_json dev-lead:hands-off > "$D/labels.recheck.3.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'returned a GraphQL errors envelope'
  echo "$output" | grep -q "held for a human by label 'dev-lead:hands-off'"
}

@test "unreadable label list on --pr: nothing dismissed, exit 1 (every form)" {
  local f
  for f in "${FORMS[@]}"; do
    rm -f "$D"/labels*.json "$D"/labels.missing.* "$D"/malformed.* "$D/reviews.pr1094.json"
    # the envelope form overwrites reviews.json; restore it so every form reaches the label read
    [ -e "$D/reviews.pristine.json" ] || cp "$D/reviews.json" "$D/reviews.pristine.json"
    cp "$D/reviews.pristine.json" "$D/reviews.json"
    : > "$GH_LOG"
    set_unreadable reviews "$f"
    run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
    [ "$status" -eq 1 ] || { echo "form $f: status $status: $output"; false; }
    [ -z "$(dismissed)" ] || { echo "form $f dismissed"; false; }
  done
}

@test "unreadable label list at recheck on --pr: nothing dismissed, exit 1 (every form)" {
  local f
  for f in "${FORMS[@]}"; do
    rm -f "$D"/labels*.json "$D"/labels.missing.* "$D"/malformed.*
    echo '{"data":{"repository":{"pullRequest":{"headRefOid":"8e5bc8db"}}}}' > "$D/recheck.json"
    : > "$GH_LOG"
    set_unreadable recheck "$f"
    run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
    [ "$status" -eq 1 ] || { echo "form $f: status $status: $output"; false; }
    [ -z "$(dismissed)" ] || { echo "form $f dismissed"; false; }
  done
}

@test "sweep: an unreadable label list fails the run, other PRs still dismissed (every form)" {
  local f
  for f in "${FORMS[@]}"; do
    rm -f "$D"/labels*.json "$D"/labels.missing.* "$D"/malformed.* "$D"/reviews.pr*.json "$D"/recheck.pr*.json
    : > "$GH_LOG"
    sweep_fixtures
    set_unreadable reviews "$f" 2
    # the missing form applies to every PR; the others are per PR #2
    run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
    [ "$status" -eq 1 ] || { echo "form $f: status $status: $output"; false; }
    ! grep -q 'DISMISS PRR_stale_2$' "$GH_LOG" || { echo "form $f dismissed PR 2"; false; }
    if [ "$f" != missing ]; then grep -qx 'DISMISS PRR_stale_3' "$GH_LOG" || { echo "form $f: PR 3 not dismissed"; false; }; fi
  done
}

@test "sweep: an unreadable label list at recheck fails the run" {
  sweep_fixtures
  set_unreadable recheck bad-name 2
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --sweep --apply
  [ "$status" -eq 1 ]
  ! grep -q 'DISMISS PRR_stale_2$' "$GH_LOG"
  grep -qx 'DISMISS PRR_stale_3' "$GH_LOG"
}

@test "an empty label list is readable and does not hold" {
  echo '{"pageInfo":{"hasNextPage":false},"nodes":[]}' > "$D/labels.json"
  run env GH_TOKEN=x bash "$ORCH" --owner combsmith --name .github --pr 1094 --apply
  [ "$status" -eq 0 ]
  [ "$(dismissed)" = "DISMISS PRR_stale " ]
}
