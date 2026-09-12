#!/usr/bin/env bats
# Integration tests for scripts/dismiss-stale-bot-reviews.sh — the thin I/O glue
# (#1115). These exercise the WHOLE decision path (GraphQL read → pure core →
# dismissal mutation) with a fake `gh`, so a regression in how the glue feeds the
# core surfaces here, not only in the pure-core unit tests.
#
# Fixture PR (mirrors #1094): head is 8e5bc8db; an allow-listed bot's
# CHANGES_REQUESTED sits on the superseded aca48dc4 and MUST be dismissed, while
# a same-bot review on the current head, a human review, and a bot APPROVE must
# all be left alone.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
ORCH="${REPO_ROOT}/scripts/dismiss-stale-bot-reviews.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  TT_TMP="$(mktemp -d)"
  GH_LOG="${TT_TMP}/gh.log"; export GH_LOG
  DSBR_RESPONSE="${TT_TMP}/response.json"; export DSBR_RESPONSE
  cat > "$DSBR_RESPONSE" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "headRefOid":"8e5bc8db",
  "latestReviews":{"nodes":[
    {"id":"PRR_stale","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
    {"id":"PRR_head","state":"CHANGES_REQUESTED","commit":{"oid":"8e5bc8db"},"author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
    {"id":"PRR_human","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"don-petry","__typename":"User"}},
    {"id":"PRR_approved","state":"APPROVED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
  ]}
}}}}
JSON
  # Fake gh: a mutation call (args mention dismissPullRequestReview) logs the
  # dismissed review id; any other graphql call returns the canned read response.
  local bin="${TT_TMP}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if printf '%s\0' "$@" | grep -qz 'dismissPullRequestReview'; then
  for a in "$@"; do
    case "$a" in id=*) printf 'DISMISS %s\n' "${a#id=}" >> "$GH_LOG" ;; esac
  done
  printf '{"data":{"dismissPullRequestReview":{"pullRequestReview":{"id":"x","state":"DISMISSED"}}}}'
  exit 0
fi
cat "$DSBR_RESPONSE"
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

teardown() { rm -rf "${TT_TMP:-/nonexistent}"; }

@test "dismisses ONLY the stale allow-listed bot review; leaves head/human/approved" {
  run env GH_TOKEN=x bash "$ORCH" --owner petry-projects --name .github --pr 1094
  [ "$status" -eq 0 ]
  # Assert the script's summary output before the log-inspecting `run grep` calls
  # below overwrite bats's $output.
  echo "$output" | grep -q 'dismissed 1 stale bot review'
  # exactly one dismissal, and it is the superseded bot review
  [ "$(grep -c '^DISMISS ' "$GH_LOG")" -eq 1 ]
  grep -qx 'DISMISS PRR_stale' "$GH_LOG"
  # the still-valid head review, the human review, and the approve are untouched.
  # Assert grep's exact "no match" status (1), not any non-zero: a status of 2
  # (e.g. a missing log file) would otherwise pass this negative check falsely.
  run grep -q 'DISMISS PRR_head' "$GH_LOG"
  [ "$status" -eq 1 ]
  run grep -q 'DISMISS PRR_human' "$GH_LOG"
  [ "$status" -eq 1 ]
  run grep -q 'DISMISS PRR_approved' "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "dry-run examines but dismisses nothing (no mutation)" {
  run env GH_TOKEN=x bash "$ORCH" --owner petry-projects --name .github --pr 1094 --dry-run
  [ "$status" -eq 0 ]
  # Assert the dry-run output before the `run grep` below overwrites $output.
  echo "$output" | grep -q '\[dry-run\] would dismiss review PRR_stale'
  # No mutation ran, so the log may not exist; touch it to guarantee the target
  # is present, then assert grep's exact "no match" status (1) — not a status of
  # 2 from a missing file, which would let a real dismissal slip through.
  touch "$GH_LOG"
  run grep -q '^DISMISS ' "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "pages latestReviews: dismisses a stale bot review found only on page 2" {
  # A stale allow-listed bot CHANGES_REQUESTED sits beyond the first 100-review
  # page. A single unpaginated read would drop it (fail-open, #1116); the glue
  # must follow pageInfo.endCursor and still dismiss it.
  DSBR_PAGE1="${TT_TMP}/page1.json"; export DSBR_PAGE1
  DSBR_PAGE2="${TT_TMP}/page2.json"; export DSBR_PAGE2
  cat > "$DSBR_PAGE1" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "headRefOid":"8e5bc8db",
  "latestReviews":{
    "pageInfo":{"hasNextPage":true,"endCursor":"CURSOR2"},
    "nodes":[
      {"id":"PRR_head_p1","state":"CHANGES_REQUESTED","commit":{"oid":"8e5bc8db"},"author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]
  }
}}}}
JSON
  cat > "$DSBR_PAGE2" <<'JSON'
{"data":{"repository":{"pullRequest":{
  "headRefOid":"8e5bc8db",
  "latestReviews":{
    "pageInfo":{"hasNextPage":false,"endCursor":null},
    "nodes":[
      {"id":"PRR_stale_p2","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]
  }
}}}}
JSON
  # Fake gh: dismissal logs the id; a read returns page 2 when the endCursor is
  # presented, else page 1.
  cat > "${TT_TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if printf '%s\0' "$@" | grep -qz 'dismissPullRequestReview'; then
  for a in "$@"; do
    case "$a" in id=*) printf 'DISMISS %s\n' "${a#id=}" >> "$GH_LOG" ;; esac
  done
  printf '{"data":{"dismissPullRequestReview":{"pullRequestReview":{"id":"x","state":"DISMISSED"}}}}'
  exit 0
fi
for a in "$@"; do
  case "$a" in cursor=CURSOR2) cat "$DSBR_PAGE2"; exit 0 ;; esac
done
cat "$DSBR_PAGE1"
STUB
  chmod +x "${TT_TMP}/bin/gh"

  run env GH_TOKEN=x bash "$ORCH" --owner petry-projects --name .github --pr 1094
  [ "$status" -eq 0 ]
  # Assert the paginated summary before the `run grep` below overwrites $output.
  echo "$output" | grep -q 'examined 2 effective review(s), dismissed 1 stale bot review'
  # the page-2 stale review is dismissed; the page-1 head review is left alone
  [ "$(grep -c '^DISMISS ' "$GH_LOG")" -eq 1 ]
  grep -qx 'DISMISS PRR_stale_p2' "$GH_LOG"
  run grep -q 'DISMISS PRR_head_p1' "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "no-op when the PR head moves between the read and the dismissal loop" {
  # The paginated read sees head 8e5bc8db with a stale allow-listed bot review on
  # the superseded aca48dc4, but a force-push moves the head before the mutation
  # loop. The revalidation re-read returns the new head, so the run must dismiss
  # nothing rather than clear a review that may sit on the new head (#1116).
  cat > "${TT_TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if printf '%s\0' "$@" | grep -qz 'dismissPullRequestReview'; then
  for a in "$@"; do case "$a" in id=*) printf 'DISMISS %s\n' "${a#id=}" >> "$GH_LOG" ;; esac; done
  printf '{"data":{"dismissPullRequestReview":{"pullRequestReview":{"id":"x","state":"DISMISSED"}}}}'
  exit 0
fi
# The paginated read requests latestReviews; the revalidation re-read does not.
if printf '%s\0' "$@" | grep -qz 'latestReviews'; then
  printf '%s' '{"data":{"repository":{"pullRequest":{"headRefOid":"8e5bc8db","latestReviews":{"nodes":[{"id":"PRR_stale","state":"CHANGES_REQUESTED","commit":{"oid":"aca48dc4"},"author":{"login":"coderabbitai[bot]","__typename":"Bot"}}]}}}}}'
  exit 0
fi
printf '%s' '{"data":{"repository":{"pullRequest":{"headRefOid":"deadbeef"}}}}'
STUB
  chmod +x "${TT_TMP}/bin/gh"

  run env GH_TOKEN=x bash "$ORCH" --owner petry-projects --name .github --pr 1094
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'PR head moved from 8e5bc8db to deadbeef'
  # nothing was dismissed
  touch "$GH_LOG"
  run grep -q '^DISMISS ' "$GH_LOG"
  [ "$status" -eq 1 ]
}

@test "does not report a dismissal when the mutation returns a GraphQL errors envelope" {
  # GitHub can return HTTP 200 with an `errors` envelope (e.g. the review was
  # already dismissed by another actor) and gh exits 0. The glue must not count
  # that as a dismissal or the review may still block the PR (#1116).
  cat > "${TT_TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if printf '%s\0' "$@" | grep -qz 'dismissPullRequestReview'; then
  printf '%s' '{"errors":[{"message":"review already dismissed"}]}'
  exit 0
fi
cat "$DSBR_RESPONSE"
STUB
  chmod +x "${TT_TMP}/bin/gh"

  run env GH_TOKEN=x bash "$ORCH" --owner petry-projects --name .github --pr 1094
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'returned a GraphQL errors envelope'
  # the phantom dismissal is not counted
  echo "$output" | grep -q 'dismissed 0 stale bot review'
}

@test "requires --owner, --name and --pr" {
  run env GH_TOKEN=x bash "$ORCH" --owner petry-projects --name .github
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'required'
}
