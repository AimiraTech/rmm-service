# Skill Registry — rmm-service

Generated: 2026-05-25
Project: rmm-service (Dockerized RustDesk server)

## Index

| Skill | Trigger / Description | Scope | Path |
|---|---|---|---|
| agent-vault-cli | Use when task involves third-party API credentials or env vars for secrets/API keys (CLI mode) | user | ~/.claude/skills/agent-vault-cli/SKILL.md |
| agent-vault-http | Use when task involves third-party API credentials or env vars for secrets/API keys (HTTP proxy mode) | user | ~/.claude/skills/agent-vault-http/SKILL.md |
| branch-pr | Creating, opening, or preparing PRs for review | user | ~/.claude/skills/branch-pr/SKILL.md |
| chained-pr | PRs over 400 lines, stacked PRs, review slices | user | ~/.claude/skills/chained-pr/SKILL.md |
| cognitive-doc-design | Writing guides, READMEs, RFCs, onboarding, architecture, or review-facing docs | user | ~/.claude/skills/cognitive-doc-design/SKILL.md |
| comment-writer | PR feedback, issue replies, reviews, Slack messages, or GitHub comments | user | ~/.claude/skills/comment-writer/SKILL.md |
| go-testing | Go tests, go test coverage, Bubbletea teatest, golden files | user | ~/.claude/skills/go-testing/SKILL.md |
| issue-creation | Creating GitHub issues, bug reports, or feature requests | user | ~/.claude/skills/issue-creation/SKILL.md |
| judgment-day | Judgment day, dual review, adversarial review, juzgar | user | ~/.claude/skills/judgment-day/SKILL.md |
| playwright | E2E, API, component, visual, accessibility, and security testing with Playwright | user | ~/.claude/skills/playwright/SKILL.md |
| skill-creator | New skills, agent instructions, documenting AI usage patterns | user | ~/.claude/skills/skill-creator/SKILL.md |
| skill-improver | Improve skills, audit skills, refactor skills, skill quality | user | ~/.claude/skills/skill-improver/SKILL.md |
| typescript | TypeScript strict patterns and best practices | user | ~/.claude/skills/typescript/SKILL.md |
| work-unit-commits | Implementation, commit splitting, chained PRs, keeping tests and docs with code | user | ~/.claude/skills/work-unit-commits/SKILL.md |

## Most Relevant for This Project

This project is a Dockerized RustDesk server (infrastructure/ops). The most relevant skills for day-to-day work:

- **cognitive-doc-design** — writing infrastructure docs, READMEs, architecture docs
- **work-unit-commits** — keeping commits reviewable during Docker/config implementation
- **branch-pr** — opening PRs for infrastructure changes
- **chained-pr** — splitting large Docker/compose changes into reviewable slices
- **agent-vault-cli / agent-vault-http** — injecting credentials if CI/CD or API integrations are added

## Skipped (SDD internal / support)

sdd-apply, sdd-archive, sdd-design, sdd-e2e, sdd-explore, sdd-init, sdd-onboard, sdd-propose, sdd-spec, sdd-tasks, sdd-verify, skill-registry, _shared
