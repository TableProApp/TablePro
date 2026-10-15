# Exact SQL completion proposals, 2026-10-15

Issue: [#934](https://github.com/cozyGarage/BookiE/issues/934).

## Change

GtkSourceView now receives proposal objects containing separate display names and complete insertion SQL. Raw column names use the existing dialect quoting helper. Table proposals retain their catalog-qualified references. Arbitrary editor words are no longer a second source of candidates. The shared word buffer and its cursor-driven rebuilds are removed.

Activation checks the metadata generation, source text and cursor before editing. It replaces the complete current identifier, or the qualified relation in table position, in one undo action. Alias-qualified columns retain the alias. Suggestions stay out of literals and comments.

## Regression evidence

The initial direct GtkSourceView provider-population regression failed with the word provider: the requested complete relation proposal was absent. The replacement provider passes actual GtkSourceView population and activation tests for mixed case beside lowercase, dotted names and schemas, escaped quotes, reserved words and Unicode names with spaces. Tests also assert mid-identifier replacement, preserved aliases and refusal of retired proposals.

The final isolated widget tier passed all 52 registered tests, including the three new provider regressions and atomic undo. App Clippy passed with warnings denied. Pure tests cover qualification, all five dialect delimiters, scoped candidates and refusal inside literals and comments.

The native PostgreSQL `completion_metadata_preserves_exact_postgresql_catalog_names` fixture passed locally. Its six relation identities are the same matrix asserted by the widget activation test. Native SELECT metadata identifies each intended relation separately, including `Users` and `users`. This composes the exact inserted-reference assertion with the server identity check; it is not a combined installed-UI/server scenario.

Keyboard popup selection, undo and screen reader checks are recorded in [manual verification](../manual-verification-0.2-features.md#exact-sql-completion). No screen reader result is claimed.

GtkSourceView retains its native popup and keyboard bindings. Upstream [completion list bindings](https://github.com/GNOME/gtksourceview/blob/master/gtksourceview/gtksourcecompletionlistbox.c) route Return and Tab through proposal activation. The [completion dispatcher](https://github.com/GNOME/gtksourceview/blob/master/gtksourceview/gtksourcecompletion.c) calls the provider activation method. This source review does not replace the pending desktop keyboard and screen reader checks.

Final local preflight passed: script harness, size/panic/comment/crate/bounded-operation guards, formatting, non-GTK Clippy, unit tests and sandbox integrations. Documentation links and issue ledger checks passed.

A final review reproduced alias scope loss after whitespace following a dot. The new regression offered both joined tables’ columns and keywords before the fix. The shared qualifier check now treats trailing whitespace after the dot as part of the same qualification. Completed identifiers followed by whitespace still start a new completion position.

The panic guard misclassified the ordinary nested test module until its existing explicit-path convention was used. An isolated miniature Rust tree also showed the inverse: the guard accepted an ungated production panic in a different nearby module. This independent enforcement defect is tracked in [#961](https://github.com/cozyGarage/BookiE/issues/961), with the reproduction and required regression cases. No production panic in BookiE is claimed.

The incomplete-quote check also has a failing-first MySQL regression: double quotes are strings in the existing default grammar, so an unfinished double-quoted string must not offer SQL identifiers. Identifier completion follows the same grammar boundary.

Further boundary regressions caught keyword suggestions inside unfinished identifier quotes and an empty replacement range at the start of a quoted identifier. Both failed before their fixes. Quoted positions now offer identifiers only, and activation replaces the existing token at its start. The core lexer owns unfinished-construct classification for all dialects.

At the opening of an unfinished quote, no prefix or closing delimiter identifies a safe replacement suffix. The provider refuses suggestions at that ambiguous position; typing a prefix enables quoted completion. Actual activation tests cover bare and closed-quoted prefixes at both boundaries, unfinished quotes after a typed prefix, and refusal before ambiguous unfinished quotes.

Sonar review reported two minor redundant static lifetimes on GLib subclass name constants. They were removed without changing their inferred static types; app Clippy with warnings denied passed. No security issue was reported.
