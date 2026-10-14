# Agentic Persona Standards

Standard for defining, onboarding, and rolling out a new **agentic persona**
across the `combsmith` fleet.

A persona is a named agent role — Dev-Lead, PR-Reviewer, Bob (Scrum Master),
Mary (Analyst), Murat (Test Architect) — that helps the org **design, build,
test, deliver, and operate** its projects. This standard turns the pattern that
is already implicit across those personas into an explicit, repeatable
**Persona Definition of Done**: a manifest, a trigger checklist, a file layout,
an eval gate, and a canary onboarding step.

> **Read first.** This standard builds on, and does not restate:
> [`agent-standards.md`](agent-standards.md) (required agent files, AgentShield,
> immutable files), [`ci-standards.md`](ci-standards.md) (stub/reusable tiers,
> channel-tag versioning, canary rings), and
> [`github-settings.md`](github-settings.md) (label taxonomy). Where those apply,
> follow them; this document only adds the persona-level wrapper.

---

## 1. Principles

1. **The manifest is the index-of-record.** Every persona has exactly one
   `persona.yml` (validated against
   [`personas/persona.schema.json`](personas/persona.schema.json)). It is the
   single place a human can point at to see what a persona *is*, where it is
   *defined*, how it is *triggered*, and how it *rolls out*. Everything else
   stays where it already lives; the manifest just references it.

2. **Unify over the frameworks, do not replace them.** We build on BMAD and the
   BMAD Test Architecture module and intend to **contribute back** to them. The
   manifest layers on top of a vendored framework agent — it points *into*
   `frameworks/` at a pinned version and records any local override as an
   explicit upstream-contribution candidate. Vendored files are never
   hand-edited (see [`prompts/bmad/README.md`](https://github.com/combsmith/.github-private)
   in `.github-private` and each `frameworks/*/VENDOR.md`).

3. **Advisory by default; write is opt-in.** A new persona is assumed to be
   *advisory everywhere* (it comments, reviews, labels) and must **explicitly
   opt into write access** per surface, each with a gate label and a trust
   floor. This inverts the risk correctly: the blast radius of a new persona
   starts at "leaves a comment," not "opens a PR."

4. **Register once.** Ring membership and gate knobs live in exactly one place —
   [`canary-rings.json`](canary-rings.json). The manifest references the registry
   entry by `id`; it never restates rings or gates. `release/registry.yml` in
   `.github-private` is derived from this registry, not maintained in parallel
   (see §6).

5. **No persona reaches `stable` without an eval gate.** The held-out eval
   discipline in `.github-private` `evals/` (dev/holdout split, `holdout-guard.yml`)
   is a promotion gate, not a nicety.

---

## 2. Where a persona lives

Two-repo split, consistent with the org boundary in `AGENTS.md`
("What lives where — .github vs .github-private"):

| Artifact | Repo | Path |
|---|---|---|
| This standard + the manifest schema + the copy-me template | `.github` (org standards) | `standards/persona-standards.md`, `standards/personas/` |
| Ring registry (single source of truth) | `.github` | `standards/canary-rings.json` |
| **Persona instances** (`persona.yml` + layers + evals) | `.github-private` | `personas/<id>/`, plus the layer homes below |
| Framework agents & skills (vendored) | `.github-private` | `frameworks/<framework>/…` |
| Copilot profiles | `.github-private` | `agents/<id>.md` |
| Workflow prompt libraries | `.github-private` | `prompts/<id>/` |
| Caller stub + reusable workflow | per `canary-rings.json` `host` | `.github/workflows/…` |
| Eval sets | `.github-private` | `evals/<id>/` (dev/ + holdout/) |

The **manifest is the spine**: `personas/<id>/persona.yml` names each layer's
path. A persona may use one layer (e.g. a lone Copilot profile) or several (a
framework agent + a workflow-prompt orchestrator + an eval set), but there is
always exactly one manifest.

### Canonical instance layout (in `.github-private`)

```text
personas/<id>/
  persona.yml            # the manifest (required)
  README.md              # short human note: what this persona is, how to invoke

evals/<id>/              # NOT under personas/ — lives in the repo eval tree so it
  dev/cases.jsonl        #   inherits validate-cases.py + holdout-guard.yml for free
  holdout/cases.jsonl    #   (proposer-visible dev split; CODEOWNER-gated holdout)
```

Eval sets deliberately live under the existing `evals/<id>/` tree rather than
beside the manifest: that reuses the held-out validator and the immutability
guard without forking them (co-locating under `personas/<id>/evals/` is possible
later only by extending `HOLDOUT_GUARDED_PREFIXES`, so it is not the default).

The scaffold to copy is [`standards/personas/TEMPLATE/`](personas/TEMPLATE/).

---

## 3. The definition layers

We deliberately support more than one definition format, because the runtimes
genuinely differ. The manifest's `definition.layers[]` blesses whichever a
persona uses and points at it:

| `kind` | What it is | Home | When |
|---|---|---|---|
| `framework-agent` | A vendored BMAD-style agent (`SKILL.md` + `customize.toml`) | `frameworks/<fw>/…` | Persona is backed by an upstream framework we track and contribute to |
| `copilot-profile` | A single `agents/<id>.md` with `name`/`description`/`tools` frontmatter | `agents/` | Human-invocable from GitHub.com / IDEs |
| `workflow-prompts` | A phase-keyed prompt library filled by a shell orchestrator | `prompts/<id>/` | Persona runs as automated CI (like `dev-lead`) |
| `gh-aw` | A GitHub Agentic Workflow `.md` compiled to `.lock.yml` | `.github/workflows/` | Self-contained event-triggered agent |

**Framework-backed personas (the preferred path where a good upstream exists):**

- `definition.layers[].framework` records `name`, `upstream_repo`, `vendor_pin`
  (which **MUST** match the framework's `VENDOR.md`), and `skill`.
- Never hand-edit vendored files. Local behavior is layered via
  `local_overrides` (e.g. a `customize.toml` overlay resolved base → team → user,
  or an orchestration wrapper like `prompts/bmad/scrum-master.md` that runs the
  vendored skill non-interactively).
- Any override that is a **general** improvement MUST set
  `local_overrides.upstream_candidate: true` so it is tracked for contribution
  back rather than becoming permanent private drift.

All `SKILL.md` files still require `name` + `description` frontmatter
(AgentShield `valid-frontmatter`, `agent-standards.md`).

---

## 4. The trigger matrix (the onboarding checklist)

Every persona's `triggers` block is a **checklist of every surface it may act
on**. Fill one row per surface; anything unlisted falls back to `default_mode`.

**Surfaces** (the work-item × event families):

| Surface | Typical events | Notes |
|---|---|---|
| `issues` | `opened`, `labeled`, `commented` | Label gates arm write personas |
| `pull_request` | `opened`, `synchronize`, `ready_for_review`, `review_requested` | |
| `pull_request_review` | `submitted`, `created` (review comment) | |
| `discussion` | `created`, `labeled`, `commented` | Cannot run the agent inline — **must** bridge via `repository_dispatch`/`workflow_dispatch` (see `ci-standards.md`, issue #571) |
| `check_run` | `completed` | CI-failure follow-up |
| `schedule` | cron | Proactive / sweep work |
| `mention` | `@<bot>` in a comment | Reviewer-assignment counts here too |

**Rules:**

1. **`default_mode` is `advisory` or `off` — never `write`.** Write is only ever
   an explicit per-surface opt-in.
2. **Every `mode: write` surface MUST declare a `gate_label`** (the label that
   arms the persona, e.g. `dev-lead`) — schema-enforced.
3. **Every surface honours a trust floor.** Default `[OWNER, MEMBER,
   COLLABORATOR]`; verify `author_association` before consuming agent quota
   (this is the same trust boundary the PR-review and dev-lead paths already
   apply).
4. **Every persona defines an `opt_out_label`** (`<id>:hands-off`) that removes
   an item from its automation entirely.
5. **Most personas should be advisory on most surfaces.** The working hypothesis
   — a persona can usefully weigh in on nearly every work-item type — holds *for
   advisory participation*. Reserve `write` for the few surfaces where the
   persona genuinely authors changes, and gate each one.

Label gates and trust checks are defined operationally in `ci-standards.md`
(§ agent-trigger labels) and must reuse the existing labels rather than mint
near-duplicates.

---

## 5. Trust, permissions, and safety

- **Trust floor** — set `trust.author_association_floor`; per-surface
  `trust_floor` may tighten it but never loosen below it.
- **Permissions superset** — if the persona ships a caller stub + reusable,
  `runtime.permissions` records the full set the reusable requests, and the
  **caller stub MUST grant a superset** or the whole fleet fails with
  `startup_failure` (`ci-standards.md`). The stub carries the standard
  `SOURCE OF TRUTH` header, `secrets: inherit`, and channel-tag pin.
- **Immutable files** — a persona never modifies the files in
  [`workflow-exemptions.json`](workflow-exemptions.json) (currently
  `agent-shield.yml`).
- **AgentShield** — every definition layer is subject to the AgentShield scan;
  a persona that fails the scan cannot be onboarded.

---

## 6. Canary onboarding (the last step)

Rollout is unchanged from the existing model (`ci-standards.md` §Canary rings,
`canary-rings.json`, `scripts/canary-rollout.sh`) — the persona standard only
makes the **registration** a single action.

1. **Cut** an immutable `<id>/vX.Y.Z` at a merged, CI-passed commit on the host.
2. **Register once** — add one entry under `agents.<id>` in
   [`canary-rings.json`](canary-rings.json): `host`, `reusable`, `run_workflow`,
   `rings[]`, `gate`. This is the **only** place ring membership is written.
3. **Point the manifest at it** — `persona.yml`'s `canary.agent` MUST equal
   `<id>` and `canary.registry` MUST reference `canary-rings.json`. The manifest
   restates nothing from the registry.
4. **Stage outward** one ring at a time — `next → ring0 → ring1 → stable` — each
   a single central channel-tag move, gated by the soak/dwell defaults in the
   registry. Roll back by moving the tag to the prior immutable `vX.Y.Z`.
5. **Eval gate** — the persona's `evals.path` must exist and pass by
   `evals.required_before` (recommended: `stable`).

### Single source of truth for rings

`canary-rings.json` (public, in `.github`) is the **only hand-authored** ring
registry. Because all org repos are public, there is no topology to hide, so:

- `.github-private` `release/registry.yml` is **derived from**
  `canary-rings.json`, not maintained alongside it. Do not add a persona to both
  by hand.
- `stable`'s `"*"` member is **resolved at runtime** (all org repos minus the
  repos named in earlier rings). New consumers that adopt the caller stub join
  the `stable` ring automatically; they need not be enumerated.

This eliminates the historical drift between the two registries (divergent
`run_workflow` names and soak encodings) by construction.

---

## 7. Definition of Done — the onboarding checklist

A persona is "done" (ready for `stable`) when all of the following are true:

- [ ] `personas/<id>/persona.yml` exists and validates against `persona.schema.json`.
- [ ] `definition.layers[]` names every implementing layer; framework layers pin
      a `vendor_pin` matching the framework's `VENDOR.md`, and any local override
      sets `upstream_candidate` truthfully.
- [ ] `triggers` fills one row per surface the persona acts on; `default_mode`
      is `advisory`/`off`; every `write` surface has a `gate_label`; an
      `opt_out_label` is defined.
- [ ] `trust.author_association_floor` is set; write surfaces gate on it.
- [ ] If it ships a reusable: caller stub grants a **superset** of
      `runtime.permissions`, carries the `SOURCE OF TRUTH` header, and pins a
      channel tag.
- [ ] AgentShield passes on all layers; no immutable file is touched.
- [ ] `evals/<id>/` holds `dev/` + `holdout/` splits with ≥ `evals.min_cases`
      held-out cases; `validate-cases.py` passes and the eval gate is green.
- [ ] Exactly one `agents.<id>` entry exists in `canary-rings.json`;
      `persona.yml` `canary.agent` points at it and restates nothing.
- [ ] The persona has soaked through `next → ring0 → ring1` before `stable`.

Copy [`standards/personas/TEMPLATE/`](personas/TEMPLATE/) to start; the worked
example is **Murat** (`personas/murat/` in `.github-private`), which wraps the
vendored `bmad-test-architecture` Test Architect.

---

## 8. References

- [`agent-standards.md`](agent-standards.md) — required agent files, AgentShield, immutable files
- [`ci-standards.md`](ci-standards.md) — stub/reusable tiers, channel-tag versioning, canary rings, trigger labels
- [`canary-rings.json`](canary-rings.json) — the ring registry (single source of truth)
- [`github-settings.md`](github-settings.md) — canonical label taxonomy
- [`personas/persona.schema.json`](personas/persona.schema.json) — the manifest schema
- [`personas/TEMPLATE/`](personas/TEMPLATE/) — copy-me scaffold
