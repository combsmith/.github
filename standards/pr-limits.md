# Standard — Pull-Request Limits (automation open-PR cap)

Org-wide policy for capping how many pull requests automation keeps open at once,
the single source of truth for the configured value, where the cap is enforced,
and which actors are intentionally exempt.

This standard is the human-readable companion to the machine-readable config in
[`standards/pr-limits.json`](pr-limits.json). It exists so a compliance audit —
and any contributor — reads the cap and its exemptions as **sanctioned policy,
not misconfiguration or drift**.

- **Decision record (why this exists / why it is source-side):**
  [`docs/initiatives/pull-request-limits-adr.md`](../docs/initiatives/pull-request-limits-adr.md)
  (Story 1, [#506](https://github.com/petry-projects/.github/issues/506)).
- **Single source of truth (the values):**
  [`standards/pr-limits.json`](pr-limits.json) (Story 2,
  [#507](https://github.com/petry-projects/.github/issues/507)).
- **Apply path (where it is enforced):**
  [`scripts/lib/pr-limit-gate.sh`](../scripts/lib/pr-limit-gate.sh); live-path
  wiring + rollout scope is Story 3
  ([#508](https://github.com/petry-projects/.github/issues/508)).

---

## 1. What is limited

A **soft ceiling on the number of concurrent open, non-draft _automation_ pull
requests org-wide.** When the standing queue is at or over the ceiling, a
PR-creating automation source **defers** opening another PR rather than adding to
the backlog; it does not delete, close, or fail anything.

Why a cap at all: automation opens PRs faster than they merge. With
`code-quality`'s `strict_required_status_checks_policy: true` (branches must be
up to date), every merge to `main` re-stales the other open PRs and the
auto-rebase fan-out re-runs CI on the behind PRs. Bounding the standing queue
bounds that fan-out cost. See ADR §1 for the measured baseline.

**Only non-Dependabot automation counts toward the ceiling.** Dependabot is
already bounded per-ecosystem by its own `open-pull-requests-limit` (see
[`standards/dependabot-policy.md`](dependabot-policy.md)); counting it here would
double-cap it and risk starving a security PR. See §5 and ADR §7.4.

## 2. Source of truth — the configured value

The signed-off **default** cap value, any per-source sub-caps, and the exempt
lists live **only** in [`standards/pr-limits.json`](pr-limits.json). The cap in
force can be overridden at runtime by the org variable in §2.1. This document
deliberately does **not** restate the number: a changeable value stated in prose
is a second place to forget to update. To read the default cap, read the config:

```bash
jq '.org_wide.automation_open_pr_cap' standards/pr-limits.json
```

The config carries its own inline `_note` fields recording the human sign-off
(epic [#505](https://github.com/petry-projects/.github/issues/505) gate) and the
rationale for the number. Consumers (the apply path in §3, and any future
PR-creating workflow) **must** resolve the cap via `plg_effective_org_cap`
(override, then this file) — never hardcode it.

### 2.1 Runtime override — the org-level variable

The ceiling can be changed **on the fly, with no code change or PR**, via the
org-level Actions variable **`PR_LIMITS_ORG_CAP`** (Org → Settings → Secrets and
variables → Actions → Variables). Consumers pass it to the gate as the
`PR_LIMITS_ORG_CAP` environment variable (`env: PR_LIMITS_ORG_CAP: ${{ vars.PR_LIMITS_ORG_CAP }}`).

- **Precedence:** a positive-integer `PR_LIMITS_ORG_CAP` (at most 9 digits, no
  leading zeros) wins; if it is unset or empty (the normal "variable not set"
  case, silent), or invalid (zero, negative, non-integer, leading zeros, more than
  9 digits — logged as a warning), the gate falls back to `org_wide.automation_open_pr_cap` in the config. A bad value can
  never silently disable or zero the cap.
- The file value is the **default/fallback**; the variable is the **operational
  lever**. Exempt actors/labels and sub-caps still come only from the config.
- Resolution lives in one place (`plg_effective_org_cap` in the gate library) and
  is reused by [`scripts/pr-limits-report.sh`](../scripts/pr-limits-report.sh), so
  the gate and the daily report always agree.
- Set or change it with `gh variable set PR_LIMITS_ORG_CAP --org petry-projects --visibility all --body <N>`.
  Take effect on the next run of each consumer; remove it to revert to the file.
- **Wiring:** this repo's report workflow already passes it. The PR-creation
  engine in `petry-projects/.github-private` must add the same `env:` line to the
  step that sources the gate for the variable to take effect there.

Its contract (parseable JSON, positive-integer cap, required keys,
`dependabot[bot]` and the `security` label present on the exempt lists) is
guarded by [`test/scripts/pr-limits/pr-limits-config.bats`](../test/scripts/pr-limits/pr-limits-config.bats),
run in CI by [`.github/workflows/pr-limits-tests.yml`](../.github/workflows/pr-limits-tests.yml).

## 3. Where it is applied — the apply path

GitHub exposes **no native "maximum open PRs" surface** — not a repo setting, not
an org setting, not a ruleset rule (ADR §2–§3 verified this against GitHub's own
docs). There is therefore nothing for `apply-repo-settings.sh` or
`apply-rulesets.sh` to PATCH or PUT. The cap is instead enforced **source-side**,
at the automation that creates the PRs.

The enforcement library is
[`scripts/lib/pr-limit-gate.sh`](../scripts/lib/pr-limit-gate.sh). A PR-creating
workflow sources it and calls `plg_admission_gate <source>` before opening a PR:

1. If `<source>` is an exempt actor (§4) → **allow** (never blocked, never counted).
2. Else it counts the open, non-draft, non-exempt automation queue org-wide via
   `gh search prs` (the enumeration lives in the gate library itself) and, if
   the queue is at or over the effective cap (`plg_effective_org_cap`: the
   `PR_LIMITS_ORG_CAP` override (§2.1) if set and valid, else
   `org_wide.automation_open_pr_cap`) → **defer**.
3. If a per-source sub-cap is configured for `<source>` and its own queue is at
   or over it → **defer**. (No sub-caps are configured under the current
   signed-off policy; the map is intentionally empty.)
4. Otherwise → **allow**.

The gate is fail-open (a transient `gh` error yields a count of `0` and an allow)
and honours `DRY_RUN` / `DEV_LEAD_DRY_RUN` by computing and logging the decision
but always returning allow.

> **Wiring status.** The library and its tests exist, and the gate is now wired
> into the PR-creation engine in `petry-projects/.github-private` (**Story 3**,
> [#508](https://github.com/petry-projects/.github/issues/508)). Enforcement
> activates as that change promotes through the dev-lead channels (ring0 →
> stable) via the normal canary soak — so the gate is wired but not yet
> enforcing on the running channel.

## 4. Exempt actors — sanctioned, not a misconfiguration

Some PRs must **never** be blocked or deferred by the cap. These actors and
labels are listed in `exempt_actors` / `exempt_labels` in
[`standards/pr-limits.json`](pr-limits.json) and are excluded both from being
blocked *and* from being counted toward the ceiling (ADR §7.4). This is a
**deliberate, signed-off exemption** — mirroring how this org documents the
ruleset bypass-actor allowance (`OrganizationAdmin` + the dependabot app, see
[`standards/ruleset-remediation-runbook.md`](ruleset-remediation-runbook.md)). A
compliance audit encountering these actors on the exempt list should treat them
as policy, not drift.

| Exempt entry | Kind | Why it is exempt |
|---|---|---|
| `dependabot[bot]` | actor | Already bounded per-ecosystem by `open-pull-requests-limit` (see §5). Security update PRs must never be starved by a general throttle. |
| `OrganizationAdmin` | actor | Human break-glass / admin PRs. |
| `@petry-projects/org-leads` | actor | Maintainer PRs — human review traffic, not automation backlog. |
| `dependabot-automerge-petry` | actor (App) | Operates on *existing* PRs (approve / merge); it does not add to the open-PR queue. |
| `security` | label | Urgent security / hotfix PRs bypass any throttle. |

To change this list, follow the runbook in §6.2.

## 5. Reconciliation with the Dependabot cap

The two caps are complementary and must not double-count:

- **Dependabot's own cap** — `open-pull-requests-limit` in each repo's
  `dependabot.yml` (policy in [`standards/dependabot-policy.md`](dependabot-policy.md))
  — remains the *sole* limit governing Dependabot volume.
- **This automation cap** counts and limits **only non-Dependabot** sources.
  `dependabot[bot]` is on the exempt list (§4) precisely so it stays governed by
  its own ecosystem limit and a security PR is never blocked by the general
  ceiling.

This keeps a single source of truth *per actor*: Dependabot's number lives in
`dependabot.yml`; every other automation source is bounded by
`standards/pr-limits.json`.

## 6. Operator runbook

Changes here are either edits to the single source of truth
[`standards/pr-limits.json`](pr-limits.json) (the default, gated by the config
tests) or a change to the `PR_LIMITS_ORG_CAP` org Actions variable (the runtime
override, §2.1, not gated by tests). Neither touches a repo setting or ruleset —
there is no such surface to apply (§3).

### 6.0 Quick change (no PR)

Set the org variable (§2.1): `gh variable set PR_LIMITS_ORG_CAP --org petry-projects --visibility all --body <N>`.
Use §6.1 only to change the signed-off default in the file.

### 6.1 Change the limit and re-apply it

1. Edit `org_wide.automation_open_pr_cap` in
   [`standards/pr-limits.json`](pr-limits.json). Update the adjacent `_note` to
   record the new rationale and sign-off (keep the value out of any other prose
   — this file is the only place it should appear).
2. Validate the contract locally:

   ```bash
   bats test/scripts/pr-limits/pr-limits-config.bats
   ```

3. Open a PR. CI ([`.github/workflows/pr-limits-tests.yml`](../.github/workflows/pr-limits-tests.yml))
   re-runs the config + gate tests.
4. **Re-apply = nothing to deploy.** Because enforcement is source-side and reads
   the file at run time (§2–§3), the new default takes effect for every consumer
   as soon as the change merges to `main` — unless a valid `PR_LIMITS_ORG_CAP`
   override (§2.1) is set, in which case the file value is only the fallback — there is no `apply-*.sh` run and no
   GitHub setting to push. (Per-repo Dependabot caps, if you also changed those,
   are applied through `dependabot.yml`, not this file.)

### 6.2 Add or remove an exempt actor

1. Edit the `exempt_actors` array (or `exempt_labels` for a label) in
   [`standards/pr-limits.json`](pr-limits.json). Add a short justification to the
   `_exempt_note`, matching the style of the existing entries and §4 of this doc,
   so the exemption stays self-documenting for the next audit.
2. Keep this document's §4 table in sync with the config so the human-readable
   rationale does not drift from the machine-readable list.
3. Validate and open a PR as in §6.1 (steps 2–4). The change takes effect on
   merge; no separate apply step.

> **Exempt = never counted, never blocked.** Removing an actor from the list
> means its PRs begin counting toward the ceiling and can be deferred. Adding a
> per-source sub-cap (an entry under `per_source_caps`) is the opposite lever:
> it *tightens* one source without changing the org-wide ceiling. Both are read
> by [`scripts/lib/pr-limit-gate.sh`](../scripts/lib/pr-limit-gate.sh).

## 7. References

- [`docs/initiatives/pull-request-limits-adr.md`](../docs/initiatives/pull-request-limits-adr.md)
  — decision record (Story 1, #506).
- [`standards/pr-limits.json`](pr-limits.json) — single source of truth (Story 2, #507).
- [`scripts/lib/pr-limit-gate.sh`](../scripts/lib/pr-limit-gate.sh) — source-side
  admission gate (does its own `gh search prs` enumeration); wired into the
  PR-creation engine in `petry-projects/.github-private` (Story 3).
- [`standards/dependabot-policy.md`](dependabot-policy.md) — the complementary
  per-ecosystem Dependabot cap.
- [`test/scripts/pr-limits/`](../test/scripts/pr-limits) — config + gate tests.
