# auto-rebase scripts

Supporting logic for the org-level **auto-rebase** reusable workflow
(`.github/workflows/auto-rebase-reusable.yml`). All bash/jq decision logic
lives here so it can be unit-tested with bats
(`test/workflows/auto-rebase/`) instead of being trapped inline in YAML.

The reusable workflow checks this repo out at `inputs.tooling_ref` and sources
`lib/eligibility.sh` to decide which out-of-date PRs are eligible, then
`lib/update-gate.sh` to decide whether being behind actually blocks each one. `tooling_ref`
defaults to empty, which resolves to the reusable's own commit
(`github.job_workflow_sha`) so the predicate always matches the pinned
workflow version. Set `tooling_ref` only to test a branch end-to-end.

## `lib/eligibility.sh`

Pure, side-effect-free predicate. Source the file, then call:

| Function | Input | Returns |
|----------|-------|---------|
| `auto_rebase_pr_eligible MODE` | mode string | `0` eligible, `2` unknown mode |

### Eligibility modes (the tunable `eligibility` workflow input)

| Mode | Meaning |
|------|---------|
| `all` (default) | every behind PR, including drafts |

New modes (e.g. a future "front-of-queue N") can be added here and selected by
callers via the `eligibility` input with no change to the workflow file.

## `lib/comments.sh`

Thin best-effort I/O wrapper around `gh pr comment` (not a pure predicate).
Source the file, then call:

| Function | Input | Returns |
|----------|-------|---------|
| `auto_rebase_post_comment_best_effort PR_NUMBER REPO BODY` | PR number, `owner/repo`, comment body | always `0` — posts the comment; on failure logs a `::warning::` and swallows the error |

### Why best-effort (issue #594)

The reusable posts a conflict-resolution comment when a branch update hits a
merge conflict. That `gh pr comment` used to run unguarded under
`shell: bash -e`, so a single PR that had hit GitHub's **2500-comment cap**
(`Commenting is disabled on issues with more than 2500 comments`) failed the
whole step — starving every *other* open PR of its rebase in the same run. A
best-effort notification must never be fatal to the core function of rebasing
the other PRs, so this helper logs a warning and returns `0` on any
comment-side error (comment cap, secondary rate limit, transient 5xx).

## `lib/update-gate.sh` and `lib/gate-facts.sh`

`lib/gate-facts.sh` is the I/O glue (reads rules and mergeability state, polls);
`lib/update-gate.sh` is the pure decision. Together they decide whether a PR that is **behind** its
base should actually be updated (issue #1272). Updating pushes a merge commit, which creates a new
head SHA and restarts every review, test and bot-review cycle on the PR. That is only worth doing
when being behind blocks something, so a behind PR is updated only when the base branch's
*effective* rules require branches to be up to date. The gate reads them through the API, from the
active rulesets (`GET /repos/{repo}/rules/branches/{branch}`,
`strict_required_status_checks_policy`) and from classic protection
(`GET /repos/{repo}/branches/{branch}/protection/required_status_checks`, `.strict`). Nothing is
hard-coded, so re-enabling the strict policy brings back update-every-behind-PR with no code change.

Merge-queue membership and auto-merge are deliberately not conditions: with the strict policy off,
being behind does not stop a PR entering the queue, and the queue builds its own merge commit.

A PR in **merge conflict** (`mergeable: CONFLICTING`) is still attempted, so the
existing conflict notice and dev-lead recovery still fire. While GitHub is
still computing mergeability (`UNKNOWN`, common right after a base push), the
gate re-polls a few times.

**Fail safe.** If something can't be read, the PR is updated just as it was
before the gate existed, and the log line says `could not evaluate`. That covers
unreadable rules or protection (API error, 403 for a token without admin
access), unreadable PR mergeability, and mergeability that is still unknown after
polling. An unreadable configuration never causes a skip.

Each behind PR gets exactly one gate-decision log line (followed by optional outcome messages):

```text
PR #N (ref) is K commit(s) behind BASE — updating branch [gate: <condition>]
  Branch updated
PR #N (ref) is K commit(s) behind BASE — skipping update [gate: none applied (...)]
```

| Function | Input | Returns |
|----------|-------|---------|
| `auto_rebase_strict_policy REPO BRANCH` | `owner/repo`, base branch | prints `true` / `false` / `unknown`; always `0` |
| `auto_rebase_pr_mergeable REPO PR` | `owner/repo`, PR number | prints `MERGEABLE` / `CONFLICTING` / `UNKNOWN`; always `0` |
| `auto_rebase_gate_decide STRICT MERGEABLE` | gathered state (pure) | prints the reason; `0` update, `1` skip, `3` mergeability pending |
| `auto_rebase_update_decision STRICT REPO PR` | strict policy + PR | prints the reason; `0` update, `1` skip (polls while pending) |

The polling tunables are `AUTO_REBASE_MERGEABLE_POLLS` (default `5`) and
`AUTO_REBASE_MERGEABLE_POLL_SECONDS` (default `3`).
