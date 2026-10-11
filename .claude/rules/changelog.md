---
paths:
  - "CHANGELOG.md"
---

# CHANGELOG

[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Entries go under `[Unreleased]`.

- **Sections**, each at most once per version and in this order: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- **An entry is one line naming the change**, not a sentence explaining it, under about 120 characters. Added and Changed name the new thing (`Open in Window for row inspector text fields.`); Fixed names the bug, not the fix (`Empty context menu when right-clicking a read-only inspector field.`). No file paths or type names; an issue reference goes at the end, `(#1234)`.
- **One entry per thing a user would notice.** Defects with the same visible symptom share an entry.
- **No entry** for a fix to something still unreleased (fold it into its entry) or for a docs-only change.
- **Credits are added at release** by `scripts/ci/changelog_credits.py`: `(#PR by @user)` for outside contributors, `(#PR)` for maintainers. Never write the credit by hand, and reword a contributor's entry in their own PR so the credit stays theirs.
- **A version may open with a lead block** of at most six lines before its first `###`, naming what a reader would notice. The update window and the Sparkle feed show only that block.
- After any edit, `grep -n '^## \[' CHANGELOG.md` must still list every released heading.
