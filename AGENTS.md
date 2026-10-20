# TablePro

Native database clients that share no code: `apple/` holds the macOS and iOS apps (Swift), `linux/` the Linux app (Rust, GTK 4). Read `apple/AGENTS.md` or `linux/AGENTS.md` before working in that folder. Claude Code loads it through the folder's `CLAUDE.md`, Codex only when started there.

## Repository map

- `apple/`, `linux/`: each app with its scripts and changelog.
- `.github/`: workflows, actions, the PR template and `plugin-registry.json`.
- `.claude/`: the path-scoped rules and the `fix-issue` and `release` skills, which Codex sees through `.agents/skills/`.
- `scripts/`: `banned-words.txt` with `check-banned-words.sh`, the PR title and changed-path checks in `scripts/ci`, and the towncrier pin in `scripts/release`.
- `appcast.xml`: the legacy feed apps up to 0.81 read from `main` (`apple/RELEASING.md`, Channels).
- `.oss-scanner/`: the build image and threat model for Anthropic's OSS Scanner. Renaming a TableProCore target that `.oss-scanner/swift/Package.swift` lists updates it there too.
- Docs site: TableProApp/docs, cloned beside this repo as `../tablepro-docs`, under its own `AGENTS.md`.

## Principles

- Tests define behavior. When a test fails, fix the code, never the test. A test that pins behavior the PR changes on purpose is updated in the same PR and named in its description.
- Verify with `.claude/skills/fix-issue/scripts/verify.sh` from the repository root. It prints `PASS`, `FAIL` or `INCONCLUSIVE`; `INCONCLUSIVE` is never a pass.
- Writing: short sentences, plain words, no em dash, no term from `scripts/banned-words.txt`. Code comments say why, never what.
- One home per fact; other docs point to it by path and section.

## Commits and PRs

- The PR title is the squash commit subject, `type(scope): description`. The body follows `.github/pull_request_template.md`.
- A rename or signature change updates every caller and test in the same commit.
- Agents merge on green with `gh pr merge <N> --auto --squash`. They create a `release/*` branch or a tag only when the maintainer says to release, and use `--admin` only on the maintainer's word.

## CI

A PR merges once its required checks pass: `.claude/rules/ci.md`, or `gh api repos/TableProApp/TablePro/rules/branches/main` for the live list. Read why a check failed before any re-run.

## Area rules

Before editing a file, read each `.claude/rules/*.md` whose `paths:` header matches it. Claude Code loads them itself.
