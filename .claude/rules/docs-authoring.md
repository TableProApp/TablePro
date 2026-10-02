---
paths:
  - "docs/**/*.mdx"
  - "docs/docs.json"
  - "docs/snippets/**/*"
  - "docs/images/**/*"
---

# Docs

- **Read `docs/STYLE.md` before writing.** It is the spec for every page.
- **Run `verify.sh docs`**, which runs the three checks CI runs on `docs/` (writing style, claims against source, links).
- **Write the docs last, or re-check every claim against the source right before committing.** Capability tables, supported-engine lists and default values go stale when a later commit in the same branch changes the code.
- **What the scripts cannot catch:** a first sentence that repeats the frontmatter `description`; `alt` text identical to the `<Frame>` caption; design rationale aimed at the reader; the product as the subject of a sentence instead of the reader's task; "you can"; a bold label used as a heading; prose that repeats the table above it; a callout the page is wrong without.
- **A page that shows UI carries a light and dark screenshot pair** (`docs/images/<name>.png` and `<name>-dark.png`) in a `<Frame>`.
- **No competitor is named in `docs/`.**
