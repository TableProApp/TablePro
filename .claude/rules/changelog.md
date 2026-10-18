---
paths:
  - "CHANGELOG.md"
  - "changelog.d/**/*"
  - "towncrier.toml"
---

# Changelog

Unreleased changes are towncrier fragments in `changelog.d/`. A release turns them into a `CHANGELOG.md` section with `scripts/release/notes.py assemble` (`RELEASING.md`, Notes).

- **One file per user-visible change**, named `changelog.d/<PR>.<type>.md`: `<PR>` is the pull request that adds it, `<type>` is `added`, `changed`, `deprecated`, `removed`, `fixed` or `security`. A second entry of the same type in one PR adds `.<n>`: `3452.fixed.2.md`.
- **One line, at most 120 characters, ending with a period.** Added and Changed name the new thing (`Open in Window for row inspector text fields.`); Fixed names the bug, not the fix (`Empty context menu when right-clicking a read-only inspector field.`). No file paths or type names.
- **No refs, no credit, no `- ` prefix.** towncrier links the PR named by the file and adds the bullet; `notes.py` adds ` by @login` when the PR's author is not a maintainer.
- **One entry per thing a user would notice.** Defects with the same visible symptom share an entry.
- **No fragment** for a fix to something still unreleased (edit that fragment instead) or for a docs-only change.
- **Only a `chore(release): vX.Y.Z` PR edits `CHANGELOG.md`.**
- **The lead block**: at most 6 lines, X.Y.0 only, passed as `notes.py assemble --lead`. The update window and the Sparkle feed show only that block.
- **`[CRITICAL]`** on a heading only for a security fix or data loss, never on a beta.
- `scripts/ci/check-changelog.py` checks the fragments and the headings in Repo Hygiene, then `towncrier build --draft --version 0.0.0` renders them. In PR title, `--pr` checks that a PR into main names each new fragment after itself and that only a release PR edits `CHANGELOG.md`.
