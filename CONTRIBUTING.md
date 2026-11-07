# Contributing to TablePro

This repository holds the native apps and the shared Rust core used by Linux and Windows. Each keeps its setup, build, test and style steps beside its code:

- macOS and iOS: [`apple/CONTRIBUTING.md`](apple/CONTRIBUTING.md).
- Linux: [`linux/CONTRIBUTING.md`](linux/CONTRIBUTING.md).
- Windows: [`windows/AGENTS.md`](windows/AGENTS.md).
- Shared Rust core: [`core/AGENTS.md`](core/AGENTS.md).

[`AGENTS.md`](AGENTS.md) holds the rules every app follows, and each app's `AGENTS.md` adds its own. The docs site lives in [TableProApp/docs](https://github.com/TableProApp/docs). Release guides live beside each app: [Apple](apple/RELEASING.md), [Linux](linux/docs/releasing.md) and [Windows](windows/RELEASING.md).

## Setup

Follow the platform guides above for setup. Windows build commands are in [`windows/AGENTS.md`, Commands](windows/AGENTS.md#commands), and core commands are in [`core/AGENTS.md`, Commands](core/AGENTS.md#commands).

## Branch naming

Branch off `main`: `feat/add-cassandra-support`, `fix/query-editor-crash`. PRs target `main`; a Mac `release/<X.Y>` line takes only cherry-picks of fixes already on `main` ([`apple/RELEASING.md`](apple/RELEASING.md#branches)).

## Pull requests

One logical change per PR, described with the template the PR form opens with. The title format and types are in the top comment of `.github/pull_request_template.md`. A PR merges when its required checks pass: `.claude/rules/ci.md`, Required checks. What a PR for each app carries: its `AGENTS.md`, Every change.

## Reporting bugs

Open a [GitHub issue](https://github.com/TableProApp/TablePro/issues) with your platform, operating system and TablePro version, steps to reproduce, and, for a database-specific bug, the database type and version. On Linux, include your distribution and install source. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Contributions are licensed under [AGPL-3.0-or-later](LICENSE).
