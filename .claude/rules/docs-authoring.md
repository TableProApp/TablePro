---
paths:
  - "docs/**/*.mdx"
  - "docs/docs.json"
  - "docs/snippets/**/*"
  - "docs/images/**/*"
---

# Docs changes

**Read `docs/STYLE.md` in full before you write a line.** It is 341 lines, every rule carries the defect that produced it, and nothing else in this repo tells you it exists. A page that reads fine and passes CI can still be wrong in six ways it names.

## The two scripts are not optional, and neither is in `verify.sh lint`

```bash
cd docs
bash scripts/check-writing-style.sh
python3 scripts/check-docs-against-source.py
```

`verify.sh lint` prints a line beginning `agent docs:`. That is `scripts/check-doc-symbols.sh` checking `CLAUDE.md` and `.claude/` for stale symbols. **It does not look at `docs/` at all.** Reading it as docs validation is how a page shipped with a wrong capability table and a wrong keyboard shortcut on a green local run.

## What the scripts cannot catch, and what shipped because of it

The mechanical checks cover em dashes, banned filler, hedges, British spelling, split menu paths, bold shortcuts, modifier glyphs, H4 headings, and the three claims checked against source (menu paths, shortcuts, PluginKit version). Everything below passed all of them:

- **The first sentence restating the frontmatter `description`.** Mintlify prints the description under the H1, so the reader sees the same sentence twice. STYLE.md §4.
- **`alt` identical to the `<Frame>` caption.** 21 pairs once were. STYLE.md §10.
- **Design rationale.** Put "we did it this way because" in front of every clause; if it still reads correctly, cut it. STYLE.md §2 counted 464 such clauses.
- **The product as the subject.** "TablePro tells the three cases apart" is a sentence about the app, not about the reader's task. 409 sentences opened that way.
- **`you can`.** Banned by STYLE.md §2 and not caught by any script. It is the same sentence with the subject moved.
- **A `**Label**` paragraph or bullet used as structure.** It is an H3, a table row, or a `<ParamField>`. STYLE.md §5.
- **Prose restating a table that sits directly above it.** STYLE.md §5.
- **A load-bearing callout.** If deleting it leaves the page wrong, it is not a callout. STYLE.md §8.

## Facts drift when the code moves after the page is written

STYLE.md §9 says to verify every fact against the source rather than against the page you were editing. The failure mode that rule does not spell out is **ordering**: a docs page written early in a task, then a code review that changes what the code does, then no re-read of the page.

That shipped a capability table claiming Redshift, CockroachDB and PGlite supported stored procedures. They did at the moment the table was typed; a later commit in the same branch removed their capability flags because their driver subclasses implement none of it, and nobody re-read the page.

**So: write the docs last, or re-verify every claim against the source immediately before you commit.** A capability table, a supported-engine list, and a default value are the three that rot fastest.

## Before the pull request

Read your batch's page openings consecutively in sidebar order. If two rhyme, rewrite one. This is the check STYLE.md §3 says is invisible from inside the file and obvious from three pages away, and it is the reason two rewrite passes failed in three different costumes.

This rule adds domain constraints and does not pick your workflow.
