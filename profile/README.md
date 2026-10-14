# Petry Projects

A collection of open-source tools and experiments spanning terminal UX, market data, AI content tooling, beekeeping tech, and agent orchestration.

---

## Projects

| Repository | Description | Language |
| --- | --- | --- |
| [TalkTerm](https://github.com/combsmith/TalkTerm) | Terminal-based communication tool | HTML |
| [markets](https://github.com/combsmith/markets) | Market data and analysis tooling (dual-licensed AGPL / Commercial) | HTML |
| [broodly](https://github.com/combsmith/broodly) | Field-first beekeeping decision-support app — mobile-first (iOS, Android, web) via Expo + React Native with a Go GraphQL API on GCP | HTML |
| [ContentTwin](https://github.com/combsmith/ContentTwin) | AI-powered Social Media Agent for small organizations — enterprise-quality social presence at non-profit pricing | Shell |
| [bmad-bgreat-suite](https://github.com/combsmith/bmad-bgreat-suite) | BMad Operations Suite — SRE and DevOps agents and workflows for the BMad Method ecosystem | Shell |
| [google-app-scripts](https://github.com/combsmith/google-app-scripts) | A collection of Google Apps Scripts for personal productivity automation | JavaScript |
| [.github-private](https://github.com/combsmith/.github-private) | Org-wide Copilot custom agents, Claude Code skills, and agentic workflow infrastructure | JavaScript |
| [.github](https://github.com/combsmith/.github) | Organization-wide GitHub configuration, CI templates, and engineering standards | Shell |

---

## Standards & Practices

All repositories in this org follow shared engineering standards defined in [`.github`](https://github.com/combsmith/.github):

- **TDD** — tests are written before implementation; coverage gates enforced in CI
- **CodeQL** — static analysis on every PR
- **SonarCloud** — code quality and security scanning
- **Dependabot** — automated dependency updates with automerge for patch-level changes
- **Claude Code** — AI-assisted development via [agent standards](https://github.com/combsmith/.github/blob/main/AGENTS.md)

---

## Contributing

1. Fork the relevant repository and create a branch off `main`.
2. Follow the [AGENTS.md](https://github.com/combsmith/.github/blob/main/AGENTS.md) guidelines for commit style, TDD, and CI requirements.
3. Open a pull request — CI must pass before review.

Questions or feedback? Open an issue in the relevant repo.
