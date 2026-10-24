# Current-audit focused selector rerun

Run date: 2026-10-24. This is a local regression check, not CI or release acceptance.

## Source identity

- GitHub `linux` base: `2b38603a844fd6e1353ddccfcb97ddd81eb2a9e3`
- Tracked worktree diff from that commit: SHA-256 `8d069ab16643c695b9dfce04c3da3f9c80c568151767aef5f5ad4b6eb8eda4af`
- The tracked diff includes the staged documentation audit and removal of one obsolete Rust comment; no production behavior was changed.
- No untracked source files were used. Three ignored recovered evidence logs are outside the source tree and were not used by these tests. Cargo build output is outside the tracked tree.
- The selector reruns preceded this note; the preflight below includes the note but not this result section.

## Results

All eight selectors below passed on that audit worktree. The malformed-tail command selected two tests; each other command selected one.

```text
cargo test --locked -p tablepro-app malformed_tail_blocks_all_script_consumers -- --nocapture
2 passed
cargo test --locked -p tablepro-app mysql_word_character_delimiter_stops_at_keyword_boundary -- --nocapture
1 passed
cargo test --offline --locked -p tablepro-app --lib value_contract_mssql_datetimeoffset_grid_edit_preserves_local_time_offset_and_siblings -- --ignored --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_date_array_csv_and_sql_replay_preserve_sql_dmy_style -- --ignored --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_enum_first_and_last_use_qualified_type_under_shadowed_search_path -- --ignored --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_enum_range_uses_qualified_type_under_shadowed_search_path -- --ignored --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_interval_array_csv_and_sql_replay_survive_intervalstyle_change -- --ignored --nocapture
1 passed
```

The historical manifests remain unchanged: their original run identity and log warnings have not been repaired by these reruns. These results establish only the listed selectors on the tracked audit tree; they do not validate the rest of those packets or qualify a release.

## Local preflight

`bash scripts/preflight.sh` passed on 2026-10-24 at the same GitHub base. The tracked worktree diff at preflight start had SHA-256 `b1c5ab35de4d2b556c423096aaa1803c9599aac57fec5babea7a9dc52de6b88b`. Guardrails, formatting, Clippy, 2,077 non-GTK unit tests, 2,090 sandbox tests and one Redis cancellation test passed. Test harnesses also ran 409 Python tests successfully. The local preflight does not run Docker driver integration, GTK widget or installed-GTK acceptance.

This full-preflight result section was added after the command completed and is not part of the recorded preflight tree digest.

## Local preflight after documentation cleanup, October 24

`bash scripts/preflight.sh` passed on Linux base `16d9e9f55b66c90d7746ea7fc541614cb5910e0a` after the evidence moves, redaction-ledger path corrections and backlog clarification. The tracked worktree diff at run time was 2,250,050 bytes with SHA-256 `a4414525182229481b97996d6395ef40d21e2773db3c1f9925280977abc0aa18`; no untracked files were present. It passed 412 Python harness tests, repository guards, formatting, non-GTK Clippy, 2,077 non-GTK unit tests (16 skipped), 2,090 sandbox tests (65 skipped) and one Redis cancellation test. The captured local output log has SHA-256 `749e2b71ec86fa83e0b2aab4488eaa0abe828c217afb9296a5a709feb2c9c677`; it remains under ignored `target/quality` and is not committed. The command completed with exit status zero. This is local preflight evidence for that tracked tree; it does not cover Docker driver integration, GTK widgets, installed GTK or Forgejo acceptance. This paragraph was added after the run and is not included in its tracked-diff digest.

## Local integration tier

`bash scripts/ci-local.sh integration` passed on the same Linux base and tracked audit tree on 2026-10-24, from 00:10:01 to 00:28:18 UTC. Fourteen Rust test binaries reported 619 passed, zero failed and zero ignored, including all six SQL/document/key-value driver suites, PostgreSQL and SQL Server session fixtures, socket fixtures, MCP database cases, and built-in/OpenSSH authentication fixtures. The run report records commit `2b38603a844fd6e1353ddccfcb97ddd81eb2a9e3`, Rust/Cargo 1.98.1, and the same staged worktree recorded in this audit. The tracked diff SHA-256 after the run was `5db93ebd55a08016a9de7484b2b64082fa12071ff4a536b2fb68722d37d4b614`; the retained local output and report SHA-256 values are `683267a4038408cd7a40501412e4d3ada4867d7254d243ddc5b08d1ba4a42e72` and `ea9bfc15afaa706a3ccc2bade686c6773b8026e111744610de4d8dba21275c7a`. The full files remain in ignored `target/quality/20261024T001001096330Z-integration/` and were not copied into this documentation packet. This current local run supplies named output missing from the October 4 summary-only packet, but does not repair or re-identify that historical run, and is not a Forgejo acceptance gate.

## Current GTK approval scenario

`TMPDIR="$PWD/target/tmp" TABLEPRO_GTK_SCENARIO=unparseable_routine_requests_human_approval bash scripts/test-gtk-safety.sh` passed on the same base and audit tree. The isolated D-Bus/Xvfb runner built the `ci` profile app binary and reported the scenario passed in 5.623 seconds. The script exited 0; teardown also printed `A connection to the bus can't be made`, so that shutdown output is retained as a caveat rather than counted as a scenario failure. The full tracked diff SHA-256 was `86a0b6d8d4a1b281556f9d84d0bf3fad6d4679acada6ac799b3475ef3361b26d`, the app/crate source diff SHA-256 was `dae7a847c8591534fdec24a8c6d159edb6a1bf8fb768b26db2b2f268657769e4`, and the built binary SHA-256 was `2cab96a5cd6aadc4e16ed3ca1d86e989a3b4f2741c99620e2e4db1c8fb642246`. This is one current Xvfb scenario, not the historical 29-scenario run, installed-package acceptance or native Wayland validation.

## Additional source-identity case reruns

These focused reruns were made on the same base commit. The tracked worktree diff at their start had SHA-256 `a02e8fdf9250e3bc73b8fc23f963b6719b04afde9b78bb7630ce5761a0151f1f`.

The DuckDB case is an application library test, so it required the optional feature:

```text
cargo test --offline --locked -p tablepro-app --features duckdb --lib value_contract_duckdb_enum_list_result_matches_native_json -- --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-mysql --test integration value_contract_enum_and_set_consumers_survive_mariadb_sql_modes -- --ignored --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_custom_enum_array_agg_distinct_filter_preserves_native_order_and_nulls -- --ignored --nocapture
1 passed
cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_custom_enum_array_agg_keeps_target_type_under_shadowed_search_path -- --ignored --nocapture
1 passed
BOOKIEE_XLSX_REIMPORT_ARTIFACT="$PWD/target/quality/doc-audit-float4/source.xlsx" cargo test --offline --locked -p tablepro-driver-postgres --test integration value_contract_float4_array_file_exports_preserve_values_for_calc_reimport -- --ignored --nocapture
1 passed
```

All five current-source tests passed. The DuckDB optional feature compiled its bundled C++ dependency in the local Cargo target. The float4 test verified server bits, SQL-file replay, CSV text and XLSX generation. Its current XLSX A2 cell is a 66-character shared string containing `1e-45` for the minimum subnormal and has no formula. LibreOffice 24.2.7.2 in a disposable Ubuntu 24.04 container converted that workbook to ODS and back to XLSX; an XML check confirmed the 66-character text was identical in all three files, remained a string cell, and contained no formulas. The source workbook, ODS and re-exported XLSX have SHA-256 digests `afb133d9fe735eded6ef8820d3cb9e8961c60d7cf7ce7fe5f7688e9e21a0f7b7`, `ae866bd1d6405176250361207886759145631dea940a3adeb0033b67e6f13049`, and `c48f4a269c62850b6b332637e41d1fabd06a4c68b1b083c892a54fb4030a2a07`. The historical packet used LibreOffice 26.8.0.3 and a 108-character expanded-decimal cell; that exact environment has not been rerun. The current workbooks remain only under ignored `target/quality/doc-audit-float4/`.

## Current DuckDB Decimal case rerun, October 24

The focused Decimal capacity test passed against GitHub `linux` commit `16d9e9f55b66c90d7746ea7fc541614cb5910e0a`:

```text
cargo test --offline --locked -p tablepro-driver-duckdb --test integration value_contract_rust_decimal_capacity_edges_round_trip_through_duckdb -- --nocapture
1 passed, 40 filtered out (1 suite, 0.04s)
```

The tested files matched that commit: `crates/core/src/sql_literal.rs` (`e4bccbee5701dd7af55fbe506ad956e3b612824d330a0f9223bb0e0d257bac24`), `crates/drivers/duckdb/tests/integration.rs` (`4a00098929ca8d115de46c46be61dc671cd100dbe8a54a30f112bafcb5501150`), and `crates/drivers/duckdb/tests/support/rust_decimal_boundaries.rs` (`34d2fa0c0cf267e264aa244fe7094b95582a3e538d69e08a21ba0f05903abd47`). This verifies the tested maximum, minimum and sub-unit Decimal values through native parameter binding and SQL-literal replay on this source. It does not validate other DuckDB types or consumers.

## Current SQLite numeric-affinity rerun, October 24

The focused grid-edit regression passed against GitHub `linux` commit `16d9e9f55b66c90d7746ea7fc541614cb5910e0a`; the tested app and Core source files matched that commit:

```text
cargo test --offline --locked -p tablepro-app --lib ui::browse_tab::value_parse::tests::sqlite_numeric_affinity::sqlite_numeric_affinity_grid_edit_preserves_text_and_sibling_values -- --exact --nocapture
1 passed, 1007 filtered out (1 suite, 0.00s)
```

This current-source rerun covers the named SQLite grid-edit case. It does not replace the historical packet's separate CSV, constraint or full app-library results.

## Current SQLite JSON aggregate rerun, October 24

The version-aware JSON aggregate regression passed against GitHub `linux` commit `16d9e9f55b66c90d7746ea7fc541614cb5910e0a` with system SQLite 3.54.0:

```text
cargo test --offline --locked -p tablepro-app --lib ui::browse_tab::value_parse::sqlite_any_contract::sqlite_json_group_object_any_csv_round_trip_preserves_native_text -- --exact --nocapture
1 passed, 1007 filtered out (1 suite, 0.01s)
```

The test and driver manifest matched that commit. This verifies the fixed-version expectation and CSV preservation on SQLite 3.54.0. It does not reproduce the malformed output on SQLite 3.45.1 or 3.46.1, nor decide whether older system libraries should be skipped or SQLite bundled.
