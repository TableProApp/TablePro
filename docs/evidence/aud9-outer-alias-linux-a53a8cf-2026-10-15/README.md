# AUD-9 outer-alias masking recheck at `a53a8cfc`

Date: 2026-10-15

Source: `a53a8cfcf9f9987cf9c5f2a1e3db8dbb37d02bb0` (`feat(mcp): preserve structured write outcomes (#927)`).

Environment: Rust/Cargo 1.98.1, Docker Engine 29.7.2.

Command:

```bash
cargo test --locked -p tablepro-policy --test session_postgres an_agent_cannot_expose_sensitive_json_through_an_outer_alias -- --include-ignored --exact --test-threads=1
```

Result: 1 passed, 0 failed, 8 filtered out; the test completed in 4.00 seconds.

This is a local Docker-backed recheck of the outer-alias regression. It does not replace the maintainer-designated frozen-candidate Forgejo driver and PostgreSQL release acceptance required by [#600](https://github.com/cozyGarage/BookiE/issues/600).

The surrounding masking cases also passed with:

```bash
cargo test --locked -p tablepro-policy --test session_postgres an_agent_cannot_expose_sensitive -- --include-ignored --test-threads=1
```

Result: 3 passed, 0 failed, 6 filtered out; the suite completed in 8.12 seconds. The selected tests cover renamed and record projections, the outer alias, and `table_to_xml`.
