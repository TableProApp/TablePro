---
paths:
  - "**/CHANGELOG.md"
  - "**/changelog.d/**/*"
  - "**/towncrier.toml"
---

# Changelog

- A user-visible change adds one towncrier fragment to its app, `apple/changelog.d/<PR>.<type>.md` or `linux/changelog.d/<PR>.<type>.md`, where `<PR>` is the pull request that adds it. A second entry of one type adds a counter: `3452.fixed.1.md`.
- `<type>` is `added`, `changed`, `deprecated`, `removed`, `fixed` or `security`.
- One sentence per entry, in the user's terms, at most 120 characters, ending with a period. Fixed names the bug, not the fix. No bullet, PR link or credit: towncrier and `notes.py` add them.
- Only a `chore(release)` pull request edits `apple/CHANGELOG.md` or `linux/CHANGELOG.md`; PR title refuses any other.
- The release, the lead and `[CRITICAL]`: `apple/RELEASING.md`, Notes, and `linux/docs/releasing.md`.
