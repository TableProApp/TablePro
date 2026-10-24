# Changelog fragment evaluation, 2026-10-19

> Superseded on 2026-10-24 by [ADR 0022](../decisions/0022-release-notes-from-merge-commits.md): the revisit trigger below was met (284 of 1,071 commits touched `CHANGELOG.md`).

## Decision

Keep the current Keep a Changelog workflow. Do not add Towncrier fragments yet. Reconsider after a release cycle if maintainers can point to actual merge conflicts or duplicate user-facing entries caused by concurrent edits.

## Evidence

- Between 2026-10-11 and 2026-10-18, 148 commits touched `CHANGELOG.md` on the inspected `linux` history. This is a commit count, not a count of unique pull requests or conflicts.
- The current Unreleased section contains 297 bullet entries and no exact duplicate lines.
- Git history does not retain a reliable measure of resolved merge conflicts. The available evidence therefore shows high contribution volume, but does not establish that the shared section is causing meaningful lost time or duplicated release notes.
- The current convention already gives contributors a stable rule: one concise user-impact line under `[Unreleased]`; tests and audit evidence stay out of the changelog. Release notes are composed in one canonical file.

## Trade-off

Fragments would reduce edits to the shared file, but add a pinned generator, fragment naming and validation rules, release composition changes, and exceptions for security and maintenance releases. Without measured conflict cost, that extra release machinery is not justified. The upstream pattern remains a useful option if future PRs show concrete contention.

## Revisit trigger

Record actual changelog merge conflicts, duplicated entries, or release-note omissions during the next release cycle. Reopen the decision if those incidents recur and exceed the maintenance cost of the fragment toolchain.
