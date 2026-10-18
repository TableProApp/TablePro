---
paths:
  - "CHANGELOG.md"
  - "changelog.d/**/*"
  - "towncrier.toml"
---

# Changelog

Unreleased changes are towncrier fragments in `changelog.d/`. A release turns them into a `CHANGELOG.md` section with `scripts/release/notes.py assemble` (`RELEASING.md`, Notes).

- **One file per user-visible change**, named `changelog.d/<PR>.<type>.md`: `<PR>` is the pull request that adds it, `<type>` is `added`, `changed`, `deprecated`, `removed`, `fixed` or `security`. A second entry of the same type in one PR adds a counter, as `towncrier create` does: `3452.fixed.1.md`, then `.2`. The counter does not order entries.
- **One line, at most 120 characters, ending with a period.** Added and Changed name the new thing (`Open in Window for row inspector text fields.`); Fixed names the bug, not the fix (`Empty context menu when right-clicking a read-only inspector field.`). No file paths or type names.
- **No refs, no credit, no `- ` prefix.** towncrier links the PR named by the file and adds the bullet; `notes.py` adds ` by @login` when the PR's author is not a maintainer.
- **One entry per thing a user would notice.** Defects with the same visible symptom share an entry.
- **No fragment** for a fix to something still unreleased (edit that fragment instead) or for a docs-only change.
- **Only a `chore(release): vX.Y.Z` PR edits `CHANGELOG.md`.**
- **The lead block and `[CRITICAL]`**: `RELEASING.md`, Notes and Channels.
- `scripts/ci/check-changelog.py` checks the fragments' text, the headings and the lead blocks in Repo Hygiene, then `towncrier build --draft --version 0.0.0` renders the fragments. towncrier refuses an unknown type and a non-numeric PR number (`ignore`, `issue_pattern`). In PR title, `--pr` checks that a PR into main names each new fragment after itself, that only a release PR edits `CHANGELOG.md`, and that a release PR changes nothing else.
