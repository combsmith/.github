# Initiative: AGENTS.md Structural Validation — Rule Set & Spec-Alignment Reference

- **Status:** Phase 1 (documentation + rule set only) — the rule set is **inert on merge**; no linter, workflow, or audit consumes it yet.
- **Date:** 2026-09-01
- **Epic:** [#642 — AGENTS.md Specification Alignment & Automated Structural Validation](https://github.com/combsmith/.github/issues/642)
- **Story:** [#643 — Phase 1: Define the AGENTS.md structural rule set and spec-alignment reference](https://github.com/combsmith/.github/issues/643)
- **Sources:** discussion [#534 — AGENTS.md Specification Alignment & Automated Validation](https://github.com/combsmith/.github/discussions/534);
  idea [#341 — Cross-Repo Standards Drift Detection via Multi-Repo Analysis](https://github.com/combsmith/.github/discussions/341)
- **Rule set:** [`scripts/lib/agents-md-rules.json`](../../scripts/lib/agents-md-rules.json)

This document is the single, reviewable **source of truth** for *what* the AGENTS.md structural validator checks and *why*. The machine-readable
rule set the linter reads lives alongside it in [`scripts/lib/agents-md-rules.json`](../../scripts/lib/agents-md-rules.json); this doc explains the
scope, the derivation, and the promotion gate. Together they replace hardcoded or contested assumptions with a single reviewable pair.

---

## 1. Initiative scope

The org's existing compliance framework — the Standards Sync audit in [`.dev-lead/scripts/aw-standards-sync.sh`](../../.dev-lead/scripts/aw-standards-sync.sh) —
today checks only file **presence** (a `200` vs `404` on the contents API) for required files such as `AGENTS.md` and `.github/CODEOWNERS`. It does not
look *inside* those files. This initiative (epic #642) adds a deterministic **structural** validator for AGENTS.md so the canonical
`combsmith/.github` AGENTS.md and its downstream copies stay structurally aligned with the evolving AAIF/agents.md spec, and cross-repo drift is
caught before it silently degrades the many tools that parse the file.

The initiative is delivered in phases:

1. **Phase 1 (this story, #643)** — derive a documented, machine-readable structural rule set from the stable subset of the spec. *No linter code.*
2. **Phase 2** — build the standalone, rule-set-driven shell linter, bats-tested.
3. **Phase 3** — wire it into the Standards Sync compliance audit (informational) plus a local canonical-AGENTS.md CI self-check.
4. **Phase 4** — provide the human-gated informational → blocking promotion mechanism.

### In scope — structural elements only

The validator targets **only stable structural elements** — the *shape* of the document, never the *meaning* of its content. The v1 rules are:

| Structural element | Rule id | Level | What it checks |
|--------------------|---------|-------|----------------|
| **Single H1 title** | `single-h1-title` | required | Exactly one level-1 heading, appearing before any deeper heading. |
| **Heading-hierarchy validity** | `heading-hierarchy-valid` | required | Heading levels never jump by more than one when descending (no H2 → H4). |
| **Cross-reference integrity** | `cross-reference-integrity` | required | In-document anchors and repo-relative file links resolve to an existing target. |
| **Org-repo import consistency** | `org-repo-import-consistency` | required | A downstream repo's AGENTS.md links back to the canonical org AGENTS.md. |
| **Fenced code-block closure** | `fenced-code-block-closure` | required | Every opened code fence is closed by a matching fence. |
| **Standards-reference section** | `standards-reference-section-present` | recommended | A section pointing to the org development standards is present. |
| **Security section** | `security-section-present` | recommended | A security / secrets-handling section is present. |
| **Testing section** | `testing-section-present` | recommended | A testing / TDD section is present. |

Every rule is tagged **`required`** or **`recommended`**. A `recommended` rule is *reported but never fails the check* — so section-presence findings
stay advisory until the required-vs-recommended split is confirmed and the check is promoted (see §4).

### Out of scope — semantic / content checks

Per discussion #534's adversarial rebuttal, semantic validation is **explicitly excluded**. The validator never judges the *meaning*, correctness,
currency, or wording of the guidance in AGENTS.md — only its structure. The excluded checks (enumerated in `out_of_scope` in the rule set) include:

- Semantic content of any section (whether the guidance is correct, current, or complete).
- Wording, tone, prose style, or readability.
- Whether a stated standard matches actual repository behaviour.
- Presence or accuracy of specific policy values (numbers, SHAs, thresholds) inside the prose.
- Section ordering or naming beyond the recommended section-presence checks.

---

## 2. The stable structural rule set (data-driven)

The rule set is a **data file the linter reads**, not logic baked into the linter. This is the key design constraint: the upstream agents.md spec is
young and moving, so the rule set must be updatable — new rules, or a required ↔ recommended re-tag — **without code changes**. This mirrors how other
org policy is codified as reviewable data (for example [`standards/pr-limits.json`](../../standards/pr-limits.json) and
[`standards/agent-rate-limits.json`](../../standards/agent-rate-limits.json)), each consumed by a thin gate rather than hardcoded.

Each rule in [`scripts/lib/agents-md-rules.json`](../../scripts/lib/agents-md-rules.json) carries:

- `id` — a unique, stable slug the linter and audit summary key findings on.
- `element` — the structural category (`heading-structure`, `cross-reference`, `import`, `code-block`, `section-presence`).
- `level` — **`required`** (can fail a blocking run) or **`recommended`** (reported, never fails).
- `applies_to` — `all` or `downstream` (the org-repo import rule exempts the canonical file itself).
- `description`, `check`, `rationale` — the human-reviewable specification of the rule.

The rule set is validated by [`tests/test_agents_md_rules_config.bats`](../../tests/test_agents_md_rules_config.bats), which enforces this contract
(valid JSON, the required/recommended tagging, the structurally-stable rules being required, section-presence rules staying recommended, and the
promotion gate). CI runs it via [`.github/workflows/agents-md-rules-tests.yml`](../../.github/workflows/agents-md-rules-tests.yml).

### AAIF / agents.md spec snapshot

The v1 rules are derived from the **stable subset** of the AAIF AGENTS.md convention, captured at:

- **Spec:** AAIF AGENTS.md convention (agents.md).
- **Source:** <https://agents.md/>
- **Captured:** 2026-09-01.

The stable subset is: a single top-level document title, a conventional Markdown heading hierarchy, resolvable in-document and relative
cross-references, and — for this org — the back-link from each downstream repo's AGENTS.md to the canonical `combsmith/.github` AGENTS.md. Section
names and their required/optional split are treated as **unstable** (hence `recommended`) because the upstream spec is young and moving. The captured
source and date live in the `spec_snapshot` block of the rule set; re-capture them when bumping the rule set's `_schema_version` for a new stable subset.

> **Why the org-repo import rule is structural, not semantic.** The canonical AGENTS.md states it "is intended to be imported by each repository's own
> AGENTS.md or CLAUDE.md." Whether a downstream AGENTS.md contains a link back to that canonical file is a checkable, structural fact — independent of
> the imported content — which is what makes cross-repo import-consistency safe to mark `required`.

---

## 3. Inherited epic metrics and cost bound

These measurable success metrics and the cost bound are **restated from epic #642** so downstream stories (Phases 2–4) inherit them verbatim.

### Measurable success metrics

- The structural check runs against the AGENTS.md of **100% of active, non-archived org repos** each Standards Sync cycle, reported in the audit
  summary issue.
- The local CI self-check annotates/fails on **100% of structurally-invalid canonical AGENTS.md** pull requests once live, verified by fixture-based
  negative tests (an observable proxy for "no invalid AGENTS.md reaches `main` undetected").
- Cross-repo import-consistency findings are surfaced for **every downstream repo** that fails to reference the canonical org-level AGENTS.md.
- Promotion to a blocking check is achieved **only after 2 consecutive audit cycles with zero confirmed false positives** (see §4).

### Zero-token cost bound

The linter is **pure, deterministic shell — zero LLM/token cost**. It runs inside the existing monthly Standards Sync workflow (30-minute timeout) and
the existing per-PR `lint.yml` job; the initiative adds **no new scheduled runs** and no new paid infrastructure. Any per-repo linter invocation is
bounded by the existing standards-sync run. This zero-token bound is a hard constraint on every later phase.

---

## 4. Informational → blocking promotion criteria

The structural check ships **informational (non-blocking)** and is promoted to **blocking** only through a deliberate, human-gated flip — never an
automatic transition. The gate is encoded in the `promotion` block of the rule set:

| Field | Value | Meaning |
|-------|-------|---------|
| `default_severity` | `informational` | On merge, findings are reported (audit summary + PR annotations) but never fail a run. |
| `target_severity` | `blocking` | The state promotion moves to. |
| `clean_cycles_required` | `2` | Two **consecutive** Standards Sync audit cycles with zero confirmed false positives. |
| `maintainer_sign_off_required` | `true` | Explicit maintainer sign-off, in addition to the clean cycles. |

**Both** conditions must hold before promotion: (1) two consecutive clean audit cycles **and** (2) explicit maintainer sign-off. This mirrors the human
sign-off gate already used for the pr-limits and agent-rate-limits configs — the numbers/policy ship inert and a maintainer arms them.

Two further guarantees:

- **`recommended` rules never block, even after promotion.** Promotion changes the *check's* severity, not any *rule's* level. Only `required`-level
  rules can fail a blocking run; `recommended`-level findings stay advisory permanently unless a rule is explicitly re-tagged to `required` (a reviewable
  edit to the rule set).
- **Section-presence rules stay `recommended` for now.** The exact required-vs-recommended split for section presence is an open question in epic #642;
  starting them advisory avoids hard-requiring a contested section list before it is confirmed.

---

## 5. References

- [`scripts/lib/agents-md-rules.json`](../../scripts/lib/agents-md-rules.json) — the machine-readable rule set (this initiative's data artifact).
- [`tests/test_agents_md_rules_config.bats`](../../tests/test_agents_md_rules_config.bats) — contract tests for the rule set.
- [`.github/workflows/agents-md-rules-tests.yml`](../../.github/workflows/agents-md-rules-tests.yml) — CI gate that runs the contract tests.
- [`.dev-lead/scripts/aw-standards-sync.sh`](../../.dev-lead/scripts/aw-standards-sync.sh) — the presence-only compliance framework this initiative extends.
- [`AGENTS.md`](../../AGENTS.md) — the canonical org-level file the import-consistency rule points downstream repos back to.
- Epic [#642](https://github.com/combsmith/.github/issues/642) · discussion [#534](https://github.com/combsmith/.github/discussions/534) · idea [#341](https://github.com/combsmith/.github/discussions/341).
