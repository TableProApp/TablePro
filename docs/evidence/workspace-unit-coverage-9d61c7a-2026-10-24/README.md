# Workspace unit coverage on Linux `9d61c7a`

Source: `9d61c7abf84b4870f969d114560d8be1be5d5393` (2026-10-24).

Environment: Rust 1.98.1, cargo-llvm-cov 0.9.1, local Linux workstation.

Command:

```sh
CARGO_BUILD_JOBS=8 cargo llvm-cov --workspace --exclude tablepro-driver-duckdb --lib --bins --json --summary-only --output-path target/coverage-current-linux.json
python3 scripts/check-coverage-floor.py target/coverage-current-linux.json
```

Result: 62,267 of 101,383 lines covered (61.42%). The committed workspace floor is 59%; the checker passed. The report JSON is a local build artifact under the ignored `target/` directory and is not included here.

Scope: this runs library and binary unit tests and excludes DuckDB to match the nightly workspace-coverage job. It does not measure Docker driver integration coverage, GTK widget tests, installed-app accessibility scenarios or end-to-end coverage. The percentage is not an assertion-quality measure.
