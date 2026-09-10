# Dameng DM8 Driver Plugin

This plugin adds native Dameng DM8 connectivity to TablePro without requiring a local DM client installation. It supports schema browsing and switching, SQL execution, row editing, transactions, DDL helpers, EXPLAIN plans, and DM8-aware completions while typing.

## Architecture

The driver has three layers:

- **Swift** (`Plugins/DamengDriverPlugin/`) implements `PluginDatabaseDriver`, schema and editing APIs, SQL completion metadata, safe parameter substitution, and result conversion.
- **C ABI** (`CDameng/CDameng.h`) exposes opaque connection and result handles. Swift copies returned values before releasing their Rust-owned storage.
- **Rust** (`Native/DamengBridge/`) owns the DM8 wire connection, transaction state, encoding detection, row limits, and panic boundary. It builds as a static library for both Apple Silicon and Intel Macs.

The protocol crates come from [`TableProApp/rust-dameng`](https://github.com/TableProApp/rust-dameng), pinned by revision in `Native/DamengBridge/Cargo.toml`. TablePro's compatibility work lives on that fork's `tablepro` branch and adds multi-column results, binary DECIMAL decoding, bounded response parsing, DM8's text EXPLAIN response, and interruptible reads. Change protocol behaviour there, then bump the `rev` and commit the refreshed lockfile. See `Native/DamengBridge/README.md`.

## Build

The build script installs the pinned Rust toolchain and creates `Native/DamengBridge/lib/libdameng_bridge.a` as a universal archive. It stays out of `Libs/`, which holds prebuilt slices that `download-libs.sh` checksum-verifies:

```bash
scripts/build-dameng.sh
scripts/generate-project.sh
xcodebuild -project TablePro.xcodeproj -scheme DamengDriver \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Use `scripts/build-dameng.sh arm64` or `x86_64` only for architecture-specific diagnostics. Do not commit generated files under `Libs/` or `target/`.

## Tests

Run protocol, bridge, and Swift tests before submitting a change:

```bash
(cd Native/DamengBridge && cargo test --locked)
xcodebuild -project TablePro.xcodeproj -scheme DamengDriverTests \
  -configuration Debug build-for-testing CODE_SIGNING_ALLOWED=NO
```

Integration tests require an isolated DM8 server, such as a container running in OrbStack. Set `TABLEPRO_DM8_INTEGRATION=1`, `DM_HOST`, `DM_PORT`, `DM_USER`, and `DM_PASSWORD`, then run the built `DamengDriverTests.xctest` bundle with `xcrun xctest`. Tests create a unique temporary schema and remove it afterward.

## Security and Limitations

The parameter binder recognizes placeholders only in SQL code, escapes text literals, and encodes bytes with `HEXTORAW`. Response bodies and LOB content are capped at 64 MiB. Native TLS is not available; use SSH, SOCKS, or Cloudflare tunneling for untrusted networks. Native binary and off-row LOB reads remain unsupported by the transport; use `RAWTOHEX` for binary values and cast CLOB values to `VARCHAR`.
