#!/usr/bin/env bash
# force_review decision for the pr-review-mention reusable workflow (#1281).
#
# Pure and side-effect-free, so it can be unit-tested with bats (see
# test/workflows/pr-review-mention/force-review.bats). The reusable sources this
# file from its own commit and acts on the verdict in "Trigger review agent".
#
# pr-review.yml in .github-private sets FORCE_REVIEW (skip the advisory-bot and
# comment-disposition waiting gates; the review itself still runs in full) only
# when the dispatch carries client_payload.force_review == true. The rule:
#   - a trusted human's @donpetry-bot comment (OWNER / MEMBER / COLLABORATOR,
#     not donpetry-bot, no automation marker) is the break-glass → force;
#   - the review_requested path never forces;
#   - a comment carrying an automation marker never forces. Agents post as the
#     owner account, so the association alone cannot tell them from a person.
# Known, accepted limit: an agent posting as the owner WITHOUT a marker is
# indistinguishable from the maintainer and is forced too.

# Body substrings that identify an agent-posted comment.
PR_REVIEW_MENTION_AUTOMATION_MARKERS=(
  '<!-- pr-review-agent'
  '<!-- pr-review-claim'
  '<!-- persona:'
  '<!-- dev-lead'
  '<!-- dependency-advisory'
  '<!-- maintainer-resolve'
  '<!-- auto-rebase-conflict'
)

# pr_review_mention_force_decision EVENT_NAME AUTHOR_ASSOC AUTHOR_LOGIN BODY
#   Prints one line "<verdict> <rule>" and returns 0. Verdicts:
#     force  dispatch with client_payload[force_review]=true
#     plain  dispatch without the flag (today's behaviour)
#     none   do not dispatch (untrusted / bot author / unsupported event)
#   AUTHOR_ASSOC, AUTHOR_LOGIN and BODY are the comment's fields; they are
#   ignored for the pull_request (review_requested) event.
pr_review_mention_force_decision() {
  local event="$1" assoc="$2" login="$3" body="$4" marker

  case "$event" in
    pull_request)
      echo "plain review-requested"
      return 0
      ;;
    issue_comment | pull_request_review_comment) ;;
    *)
      echo "none unsupported-event"
      return 0
      ;;
  esac

  case "$assoc" in
    OWNER | MEMBER | COLLABORATOR) ;;
    *)
      echo "none untrusted-association"
      return 0
      ;;
  esac

  if [[ "$login" == "donpetry-bot" || "$login" == *"[bot]" ]]; then
    echo "none bot-author"
    return 0
  fi

  for marker in "${PR_REVIEW_MENTION_AUTOMATION_MARKERS[@]}"; do
    if [[ "$body" == *"$marker"* ]]; then
      echo "plain automation-marker"
      return 0
    fi
  done

  echo "force trusted-human-comment-mention"
}
