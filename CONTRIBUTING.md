# Contributing to TablePro

This repository holds two apps that share no code. Each keeps its setup, build, test and style steps beside its code:

- macOS and iOS: [`apple/CONTRIBUTING.md`](apple/CONTRIBUTING.md).
- Linux: [`linux/CONTRIBUTING.md`](linux/CONTRIBUTING.md).

[`AGENTS.md`](AGENTS.md) holds the rules both apps meet, and each app's `AGENTS.md` adds its own. The docs site lives in [TableProApp/docs](https://github.com/TableProApp/docs), and releasing is in [`RELEASING.md`](RELEASING.md).

## Setup

macOS and iOS: [`apple/CONTRIBUTING.md`, Setup](apple/CONTRIBUTING.md#setup). Linux: [`linux/CONTRIBUTING.md`, Dev environment](linux/CONTRIBUTING.md#dev-environment).

## Branch naming

Branch off `main`: `feat/add-cassandra-support`, `fix/query-editor-crash`. PRs target `main`; a `release/<X.Y>` line takes only cherry-picks of fixes already on `main` ([`apple/RELEASING.md`](apple/RELEASING.md#branches)).

## Pull requests

One logical change per PR, described with the template the PR form opens with. The title format and types are in the top comment of `.github/pull_request_template.md`. A PR merges when its required checks pass: `.claude/rules/ci.md`, Required checks. What a PR for each app carries: its `AGENTS.md`, Every change.

## Reporting bugs

Open a [GitHub issue](https://github.com/TableProApp/TablePro/issues) with your operating system and TablePro version, steps to reproduce, and, for a database-specific bug, the database type and version.

## License

Contributions are licensed under [AGPLv3](LICENSE).
