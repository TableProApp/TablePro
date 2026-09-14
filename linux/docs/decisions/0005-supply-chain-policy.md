# 0005: Supply-chain policy

- **Status**: Accepted
- **Date**: 2026-09-15

## Context

TablePro Linux should depend on well-known, maintained crates so that upgrades stay routine and nobody inherits private forks. Some jobs still have no crate that does them correctly. Those cases need a written reason, the evidence behind it, and a condition for removing the custom code.

## Decision

Use a maintained crates.io crate whenever one does the job. Every piece of hand-written code that replaces a crate gets an entry under "Justified custom code" below, with the gap, the evidence and a watch-list trigger.

## Rationale

A crate shared with other projects gets bug reports and security fixes we would otherwise have to find ourselves. Custom code is accepted only when the crate gives wrong results for our inputs, and the entry keeps that decision reviewable.

## Consequences

Each new custom module needs an entry in this file in the same commit. Each entry is revisited when its watch-list trigger ships.

## Justified custom code

### SQL script lexer (`tablepro_core::sql_syntax::script`)

The script planner splits editor text into statements and batches per engine. It landed as a custom lexer in `script/lexer.rs`, driven by per-grammar data in `script_rules.rs`.

A time-boxed spike ran the sqlparser 0.63.0 tokenizer through a `Dialect` wrapper that forwarded every hook the tokenizer calls. These cases failed:

1. SQLite `SELECT [a]]; SELECT 2;`: `parse_quoted_ident` treats `]]` as an escaped bracket for every dialect. The tokenizer reports "Expected close delimiter ']' before EOF." and loses the rest of the script. SQLite ends a bracket identifier at the first `]`.
2. ClickHouse `// it's` and `# it's`: the tokenizer recognises `//` only for Snowflake and `#` only for Snowflake, BigQuery, MySQL and Hive, so the apostrophe opens an unterminated string.
3. MySQL `END$$` after `DELIMITER $$`: `$` is an identifier character, so the delimiter sits inside one word token. The mysql client matches delimiters in raw text.
4. A wrapper has to forward each tokenizer hook by hand. A hook added in a later sqlparser release would silently use its default instead of the wrapped dialect.

sqlparser stays a dev-dependency of tablepro-core. `lexer_matches_sqlparser_where_engines_agree` compares semicolon positions on the corpus cases where both lexers agree. `script_plan_matches_sqlite3_complete` checks the SQLite rules against `sqlite3_complete` for every prefix of its corpus.

**Watch list**: sqlparser gaining per-dialect bracket escaping and ClickHouse line comments. Re-run the spike when both ship; FB 5 already adds sqlparser as a normal dependency for type and expression parsing.

**Rejected**: pg_query, which needs a C build and covers PostgreSQL only.

### OpenSSH glue (`tablepro-ssh`)

ADR 0013 moves SSH to the system `ssh` binary. Four pieces around it are written here because no crate provides them:

1. **Askpass bridge**: `tablepro-askpass` and `askpass_bridge.rs` carry OpenSSH prompts to the app's `CredentialPrompter` over a length-delimited Unix socket that checks the peer uid. The openssh crate runs the client in batch mode and cannot answer prompts.
2. **Instance lock**: each process holds `std::fs::File::try_lock` on `<runtime>/ssh/<instance>/lock`, so a sweep never touches a live process's masters.
3. **Stale sweep**: `sweep_stale_masters` sends `-O exit` to masters left by a crashed process and removes their directories.
4. **stderr classification**: `stderr_classify.rs` maps OpenSSH messages to typed failures. The strings come from the OpenSSH 10.2 sources and captured fixtures in `crates/ssh/tests/fixtures/stderr`.

**Watch list**: a crate that drives OpenSSH with prompt callbacks and typed errors. OpenSSH changing a classified message fails the fixture tests.
