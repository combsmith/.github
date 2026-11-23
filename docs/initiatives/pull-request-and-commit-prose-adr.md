# ADR: Pull requests, commits and issues say what changed in plain words

- **Status:** Proposed (pending the Maintainer's sign-off on each rule and on the follow-ons under Consequences)
- **Date:** 2026-11-22
- **Issue:** [#1565](https://github.com/combsmith/.github/issues/1565)
- **Scope:** documentation only. No setting, ruleset, template or workflow changes here.
- **Reference implementation:** [combsmith/software-factory](https://github.com/combsmith/software-factory), which has held these rules since 2026-11-21.

**Verdict:** every repo titles a pull request `area: plain verb phrase (#issue)` and writes its body to one short
template. The squash commit takes that title and body. Issues are titled the same way, and a decision record is a short
why-log. A repo can adopt a check that holds the mechanical half.

## Context

We squash-merge, so a pull request's title and body become main's log for good. Nothing says how they should read.
Recent titles here run to 121 characters (`feat: implement issue #1545 — Rename the Dependabot App …`). Bodies come in several
shapes, and the squash message is the branch's commits, "wip" included. Decision records grow too: software-factory's
reached a median of about 1,060 words, two thirds of it restating code, before it set a word budget.

## Decision

### Pull request titles

`area: plain verb phrase (#issue)`, for example `dependabot: accept the CodeQL check from code scanning (#123)`.

- At most 72 characters. The `(#PR)` that GitHub adds to the squash subject is not counted.
- The area is the part of the repo that changed, in lowercase: a directory, a component or an agent.
- The phrase starts in lowercase, ends without a stop, and names one change. No "and" joining two.
- The issue is required. A part of a stacked change ends `(#issue, part K of M)`.
- No name from inside the code: no backticks, `snake_case`, record or trial numbers, or schema ids.

The area replaces a type such as `feat:`, which tells a reader less. One exception: a repo whose release tooling reads
Conventional Commits types keeps the type, as `feat(area): plain verb phrase (#issue)`. Today that is this repo and
`.github-private`, whose canary autocut reads `feat:` for a minor bump and `!:` for a major one
(`scripts/canary-rollout.sh`).

### Pull request bodies

Four headings, each once, in this order, each over some text:

| Heading | What it says |
|---|---|
| `## Why` | One or two plain sentences: what was wrong or missing, and what a user would notice |
| `## What changed` | A short list, one line per file or area |
| `## What to look at` | What a reviewer should check, and what the change leaves out |
| `## Decisions and protected edits` | The decision record it adds, or "none", and any protected edit with who approved it |

Then a collapsed `<details>` block, "Checks and reviews": the tests run, and each reviewer's findings taken or declined,
with reasons. Tallies go there, not above it.

pr-review's triage escalates a body that lacks three of problem, risk, test plan, rollback and monitoring. Until it
reads these headings, say risk, rollback and monitoring in one line each under What to look at.

Once a pull request has been approved, its title and body do not change, even if the approval was later dismissed.
They become the commit, so an edit would merge text no one reviewed. To change them, close the pull request and open
a new one from the same branch.

### Commits

- Squash-merge only, as `pr-quality` already enforces.
- The squash commit's title is the pull request's title, and its message is the body: `squash_merge_commit_title` is
  `PR_TITLE` and `squash_merge_commit_message` is `PR_BODY`. The standard sets the message to `COMMIT_MESSAGES` today;
  this ADR proposes `PR_BODY`, so the reviewed text is what lands.
- A commit on a branch is plain too: one short line that says what changed.

### Issue titles

`area: the problem in plain words`, at most 72 characters, one problem per issue. No `#N`, backticks, `snake_case` or
record numbers. Tags such as `[Phase 2]` belong in labels or milestones. A body says Why, What is asked, and Done when.
Issues that automation files in its own fixed format, such as Scorecard and Fleet Monitor issues, keep it.

### Decision records

For repos that keep them. A record is a short why-log that points to the code. It is not a spec: the code and its
tests hold the exact rule, and a copy goes stale when they change. Section names may follow the repo's own template;
this repo's Context is the Why.

| Part | Rule |
|---|---|
| Title | The decision as one plain sentence, at most 72 characters |
| Status | One line, at most 40 words: the date, who decided, the issue, what it replaces or extends |
| Decision | Plain sentences, or at most 8 short rows. Name the file that holds the exact form. End with "Limits:" |
| Why | Two to four sentences: the problem, the evidence, and what was rejected |
| Budget | Decision and Why together at most 300 words, or 450 for a record that replaces others |

### Enforcement

A check can hold only the mechanical half: length, shape, headings and banned marks. Whether a title names one change
in plain words stays the reviewer's call. software-factory is the reference:

| What it holds | Where |
|---|---|
| The title: length, area, lowercase phrase, no stop, issue or part, no names from the code | `tools/pr_title.py`, `problems()` |
| The body: the four headings, once each, in order, each over text; comments, `<details>` and fences hide what they hold | `tools/pr_title.py`, `body_problems()` |
| Both run in the required check from the base branch, so a pull request cannot loosen its own check; ones opened before a cutover are skipped | `tools/commits_are_the_maintainers.py` |
| A desk command checks a draft before opening: `python3 -m tools.pr_title "TITLE"`, or `--body FILE` | `tools/pr_title.py`, `main()` |
| A record's title and its word budget | `tools/check_context.py` |
| A body edited after approval holds the merge until a person approves | `kernel/`, software-factory's decision core |

For the org, this repo would offer a reusable workflow and a caller stub in `standards/workflows/`. As AGENTS.md asks,
its logic lives in a pure script with bats tests, and the workflow is thin glue. It runs on `pull_request` and
`merge_group`. It reads the title and body from the API, so a re-run sees an edit. It prints rule codes, never the
text, which is untrusted input. It starts as informational; a repo makes it required once its titles pass. Each repo
names its own four headings, so software-factory keeps "Record and protected edits".

## Consequences

- **Squash message (Maintainer).** Change `standards/github-settings.md` and `scripts/apply-repo-settings.sh`, with its
  bats test, from `COMMIT_MESSAGES` to `PR_BODY`, then apply it to the fleet. Until then, a run of
  `apply-repo-settings.sh` would reset software-factory, which uses `PR_BODY`, to `COMMIT_MESSAGES`. With `PR_BODY`, the
  canary autocut reads its signals from the title and body alone, so its owner should confirm the bump rules still hold.
- **Org template (Maintainer).** Add `.github/pull_request_template.md` here with the four headings. As the org's
  default community health file, it applies to every repo without a template of its own.
- **Agents (`.github-private`).** dev-lead's titles and body builder, and pr-review's description triage, move to these
  rules. The exception for Conventional Commits types can go once the autocut takes its bump from elsewhere.
- **The check.** One pull request here adds the reusable workflow and its stub; each repo then opts in.
- **Left out.** Dependabot keeps its own titles, and the check skips its pull requests. Whether this repo's own ADRs
  take the record budget is the Maintainer's call; existing ADRs stay as they are.

## References

- software-factory: `.github/pull_request_template.md`, `tools/pr_title.py`, `docs/development.md`, and its decision
  records on titles (0244), bodies (0246), record titles (0245), record numbers (1121) and the word budget (1166).
- [`standards/github-settings.md`](../../standards/github-settings.md), Merge Settings.
- [`scripts/canary-rollout.sh`](../../scripts/canary-rollout.sh), `_autocut_commit_signals`.
