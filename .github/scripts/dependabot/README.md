# Dependabot gate scripts

Decision logic for the org-level Dependabot reusables
(`.github/workflows/dependabot-automerge-reusable.yml` and
`.github/workflows/dependabot-rebase-reusable.yml`). Both workflows feed the
same privileged sink — a GitHub App that approves Dependabot PRs and merges
them with ruleset bypass — so the gates that protect it live here, unit-tested
with bats (`test/workflows/dependabot/`), instead of inline in YAML.

Each reusable checks this repo out at its own commit (`job.workflow_sha`) into
`.dependabot-tooling/` and sources both libs, so the gates always match the
channel the caller pinned.

## `lib/gates.sh` — pure decisions

No network calls. Each gate prints a one-line reason and returns `0` (pass) or
`1` (block). Malformed or missing input always blocks.

| Function | Passes only when |
|----------|------------------|
| `dependabot_checks_gate PR_JSON REQUIRED_JSON [SHA]` | Every check run on the head commit `COMPLETED` as `success`, `neutral` or `skipped`; every commit status is `success`; at least one check reported; every check the base branch's rules require is present; the rollup is for the head commit (and the head is `SHA` when given). Failure, cancelled, timed_out, action_required, stale, startup_failure, pending, missing, or more than one page of checks all block (#1399). |
| `dependabot_provenance_gate PR_JSON COMMITS_JSON [APP_LOGIN] [SHA]` | The full commit list was read, at least one commit is Dependabot's, and every commit is either authored by `dependabot[bot]` and committed by GitHub (`web-flow`) or `dependabot[bot]` with a verified signature, or a merge commit by `APP_LOGIN` committed by `web-flow` with a verified signature (the App's update-branch merges). Anything else — e.g. a commit someone else pushed to the branch — blocks (#1400). |
| `dependabot_required_contexts RULES_JSON` | Prints the unique required status-check names from `GET /repos/{r}/rules/branches/{b}` (returns `1` on a non-array). |

## `lib/gh-io.sh` — GitHub I/O

Reads state through `gh`, applies the gates, and performs the writes. Any read
failure fails closed.

| Function | Does |
|----------|------|
| `dependabot_merge_gate REPO PR APP_LOGIN` | Auto-merge requested + `MERGEABLE` + checks gate + provenance gate, all bound to one head SHA. Sets `DEPENDABOT_GATE_SHA` / `DEPENDABOT_GATE_REASON`. Used by the merger before every direct merge. |
| `dependabot_provenance_check REPO PR APP_LOGIN [SHA]` | Provenance gate on the live PR. Returns `0` pass, `1` block (sets `DEPENDABOT_GATE_STALE=true` when the head moved past `SHA`), `2` state unreadable. |
| `dependabot_merge_pr REPO PR SHA` | Squash-merges with `sha=SHA`, so GitHub rejects the merge if the head moved after the gate ran. |
| `dependabot_approve_and_automerge REPO PR SHA` | Approves with `commit_id=SHA` and enables auto-merge with `--match-head-commit SHA`. |
| `dependabot_revoke_automation REPO PR APP_LOGIN REASON` | Best effort: disables auto-merge and dismisses `APP_LOGIN`'s approvals. |
