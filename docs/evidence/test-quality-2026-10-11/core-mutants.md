# Mutation run on `tablepro-core`, 2026-10-11

Command, from `linux/` on `origin/linux` at `e03ac2330`:

```bash
cargo mutants --package tablepro-core --test-tool cargo --timeout 90 \
  --build-timeout 900 --jobs 3 --no-shuffle -- --lib
```

Result: 2,194 mutants in 2 hours. 1,587 caught, 369 missed, 47 timeouts, 191
unviable (did not compile). Caught share of the viable ones: 1,587 of 1,956,
about 81 percent. The full list of missed mutants is in
[core-missed-mutants.txt](core-missed-mutants.txt). Same caveats as the
[policy run](policy-mutants.md): only the crate's own `--lib` tests ran, so a
mutant that a driver or app test would catch still shows as missed, and some
missed mutants are equivalent. A timeout counts as caught by the tool, since the
mutated code hung and a test noticed.

## Files with the most missed mutants

| File | Missed | Caught |
|---|---|---|
| `sql_syntax/script/lexer.rs` | 105 | 79 |
| `sql_ddl/types.rs` | 24 | 104 |
| `import/cell.rs` | 23 | 149 |
| `sql_syntax/script/compound_tracker.rs` | 21 | 35 |
| `sql_syntax/script/script_plan.rs` | 19 | 20 |
| `tls.rs` | 17 | 11 |
| `connection.rs` | 16 | 13 |
| `import/extended_temporal.rs` | 16 | 47 |
| `driver.rs` | 13 | 9 |
| `filter.rs` | 11 | 97 |
| `sql_format/significant_tokens.rs` | 11 | 12 |
| `sql_literal.rs` | 10 | 88 |
| `sql_ddl/diff.rs` | 10 | 9 |
| `registry.rs` | 7 | 0 |

## Highest risk first

1. **The script lexer and statement plan** (`sql_syntax/script/*`, about 145
   missed). They split a script into statements, which the policy classifies. A
   split that is wrong in a quote, comment or dollar-quote case changes which
   statements the guard sees. Many survivors are probably equivalent, but this
   is the area where a wrong split would matter most, so each needs a decision.
2. **TLS mode helpers** (`tls.rs`): `TlsMode::encrypts` and `verifies_cert` can
   return a constant, or have their negation deleted, with no test failing. These
   decide whether a connection encrypts and verifies the certificate. The TLS
   behaviour is exercised by the driver TLS fixtures, which this run does not
   include, so first check whether those catch it.
3. **CSV and cell import** (`import/cell.rs`, `import/extended_temporal.rs`): the
   match guards that choose between bytes, any and unknown column kinds can be
   replaced by a constant. These are the value-preservation paths of ADR 0007.
4. **`sql_literal.rs`:** the per-driver guards for `sqlite` negative zero,
   `clickhouse` and `mssql`. A literal rendered for the wrong dialect is a
   silent value change in exports.
5. **`filter.rs`, `params.rs`, `sql_ddl`:** smaller counts, same pattern.
6. **`registry.rs`:** 7 missed and none caught, so no test pins the driver
   registry at all.

## Next

- B3 triages the value rows (3, 4, 5) and B4 the script splitting (1) and TLS
  helpers (2): add a test, mark equivalent, or cite the test in another crate.
- Rerun on the `ssh`, `transport` and storage crates.
