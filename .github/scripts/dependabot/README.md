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
| `dependabot_checks_gate PR_JSON REQUIRED_JSON [SHA]` | Agent jobs (`DEPENDABOT_AGENT_JOB_RE`, GitHub Actions only, never a required check) are not counted. Every other check run on the head commit `COMPLETED` as `success`, `neutral` or `skipped`; every commit status is `success`; at least one check reported; every check the base branch's rules require is present as a check run from the required app: the app the rule's `integration_id` names, or GitHub Actions when it names none (a commit status, or a run from any other app or with an unreadable app, does not count); the rollup is for the head commit (and the head is `SHA` when given). Failure, cancelled, timed_out, action_required, stale, startup_failure, pending, missing, or more than one page of checks all block (#1399). A check run superseded on the same commit (same app, workflow, event and name, lower databaseId) is not counted, but only when that whole key can be read and the newest run is unique and `success`; otherwise every run of the check counts, so any failure among them blocks. |
| `dependabot_provenance_gate PR_JSON COMMITS_JSON [APP_LOGIN] [SHA]` | The full commit list was read, at least one commit is Dependabot's, and every commit has a verified signature and is either authored by `dependabot[bot]` and committed by `web-flow` or `dependabot[bot]`, or a merge commit by `APP_LOGIN` committed by `web-flow` (the App's update-branch merges). Anything else — e.g. a commit someone else pushed to the branch — blocks (#1400). Returns `2`, not `1`, when the reads cannot be trusted (no head, no commits, a commit list that does not match the PR, malformed input), so a push between two reads is never taken as a foreign commit. |
| `dependabot_required_contexts RULES_JSON` | Prints the unique required checks from `GET /repos/{r}/rules/branches/{b}` as `{context, integration_id}` objects, with `integration_id` null when the rule names no app (returns `1` on a non-array). |

## `lib/gh-io.sh` — GitHub I/O

Reads state through `gh`, applies the gates, and performs the writes. Any read
failure fails closed.

| Function | Does |
|----------|------|
| `dependabot_merge_gate REPO PR APP_LOGIN` | Auto-merge requested + `MERGEABLE` + checks gate + provenance gate, all bound to one head SHA. Sets `DEPENDABOT_GATE_SHA` / `DEPENDABOT_GATE_REASON`. Used by the merger before every direct merge. |
| `dependabot_provenance_check REPO PR APP_LOGIN [SHA]` | Provenance gate on the live PR. Returns `0` pass, `1` block (sets `DEPENDABOT_GATE_STALE=true` when the head moved past `SHA`), `2` state unreadable. Reads the head again after the commit list and returns `2` if it moved in between. |
| `dependabot_merge_pr REPO PR SHA` | Squash-merges with `sha=SHA`, so GitHub rejects the merge if the head moved after the gate ran. |
| `dependabot_approve_and_automerge REPO PR SHA APP_LOGIN` | Approves with `commit_id=SHA`, enables auto-merge with `--match-head-commit SHA`, then re-reads the PR. If the head moved to a verified commit, it dismisses the approval of `SHA`; if the new head fails the gate or the PR cannot be read, it revokes everything. |
| `dependabot_dismiss_app_approvals REPO PR APP_LOGIN REASON [KEEP_SHA]` | Dismisses `APP_LOGIN`'s approvals except those of `KEEP_SHA`. Returns `1` if one may have survived. |
| `dependabot_revoke_automation REPO PR APP_LOGIN REASON` | Disables auto-merge and dismisses all of `APP_LOGIN`'s approvals. Returns `1` unless the PR reads back with auto-merge off and every dismissal succeeded, and the workflow then fails. |
| `dependabot_withdraw_app_automation REPO PR APP_LOGIN REASON` | For an update that became ineligible: dismisses `APP_LOGIN`'s approvals and disables auto-merge only if `APP_LOGIN` enabled it. |

**What this cannot make atomic.** Native auto-merge has no head-bound form that
survives a push: a writer's push does not disable it, and `--match-head-commit`
applies only when it is enabled. The re-read and the `synchronize` run together
withdraw that state on every interleaving, but not in the same instant, so a
foreign push has a short window before its run revokes. The merger is not
exposed to it: it re-runs both gates and merges with `sha=`. If the `synchronize`
run does not run at all, the state stays until something re-evaluates the PR. The
required approval of the last push should block a merge in that window, but this
has not been tested end to end. The maintainer accepted this risk on 2026-11-02
(see `standards/dependabot-policy.md`).
