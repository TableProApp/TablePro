# Threat model

## What TablePro does

TablePro is a database client. Two apps share this repository and no code:

- `apple/`: the Mac and iPhone/iPad apps, in Swift. They need Xcode, so the image cannot build them. A few `apple/Packages/TableProCore` targets compile on Linux and are built (see How to exercise it); everything else is source only.
- `linux/`: the Linux app, in Rust with GTK 4. The image builds it and its tests.

The user is trusted: the SQL they type, the connections they create, the plugins they install by hand.

## Where untrusted input enters

1. **The database server and the network to it.** A malicious or compromised server, or anyone on the path when TLS is not verified, controls every byte of the protocol, every result set and every error message. This includes the HTTP and REST engines and the SSH server of a tunnel.
2. **Database contents.** Cell values (text, BLOBs, JSON, images, PHP-serialized data), table, column and schema names, comments and object definitions can be written by another user of a shared database.
3. **Files the user opens or imports.** `.sql`, CSV/TSV, JSON/JSONL, XLSX, Parquet, SQLite and DuckDB files, `.tablepro` connection bundles, connection files from other apps (TablePlus, DBeaver, DataGrip, Navicat `.ncx`, Sequel Ace, Beekeeper), project folders scanned for credentials (`.env`, docker-compose, framework configs), `~/.pgpass`, `~/.ssh/config`.
4. **Links.** `tablepro://` deep links and database URLs (`postgresql://`, `mysql://`, `mongodb+srv://` and others in `apple/TablePro/Info.plist`) opened from a browser or another app.
5. **Local MCP clients.** The Mac app runs an MCP server on loopback. A process without a valid token, or a client acting beyond its token's scopes and connection allowlist, is untrusted. So are web pages reaching that port (DNS rebinding) and the remote MCP servers TablePro connects to as a client.
6. **AI model output.** Tool calls from a model, which database contents can steer by prompt injection.
7. **The plugin registry and the update feed.** Nothing from `updates.tablepro.app` or the network may run without a valid signature.

## Components that matter most

1. Code in this repository that parses server responses:
   - Swift: `apple/Plugins/*DriverPlugin`, the HTTP and REST engines (Trino, ClickHouse, Etcd, Google REST, DynamoDB, Snowflake, Elasticsearch and others), Teradata's TD2 protocol, Kafka with its Snappy decoder, and the C interop that reads cells out of libpq, libmariadb, FreeTDS, libmongoc, hiredis and libcassandra.
   - Rust: `linux/crates/drivers/*`, `linux/crates/net`.
2. File parsers: `apple/Packages/TableProCore/Sources/TableProTabularIO` (its own ZIP reader, XLSX XML, delimited text), `TableProImport` (`.tablepro` bundles, PBKDF2 and AES-GCM), `apple/TablePro/Core/Services/Export/ForeignApp/` (other apps' files, the Navicat cipher, a KDBX reader), `apple/TablePro/Core/Services/ProjectImport/`, `linux/crates/core/src/import`.
3. Deep links: `apple/TablePro/Core/Services/Infrastructure/DeeplinkParser.swift`, `ExternalConnectionGate.swift`, `apple/TablePro/Core/Utilities/Connection/ConnectionURLParser.swift`.
4. MCP server: `apple/TablePro/Core/MCP/` and `apple/Packages/TableProMacCore/Sources/TableProMCP/` (a hand-written HTTP parser, bearer tokens, PKCE pairing, Origin and Host checks, `MCPStatementGate`).
5. AI tools that run SQL: `apple/TablePro/Core/AI/Chat/Tools/`, `ToolApprovalCenter.swift`.
6. Plugin install and load: `apple/TablePro/Core/Plugins/Registry/`, `PluginInstaller.swift`, `PluginCodeSignatureVerifier.swift`, `PluginManager+Validation.swift`. The app is not sandboxed and disables library validation, so this check is the only gate.
7. Secrets: `apple/TablePro/Core/Storage/KeychainHelper.swift`, `apple/TablePro/Core/Sync/SyncRecordMapper.swift` (passwords must never reach CloudKit), `linux/crates/storage/src/secrets`, `TableProLogRedaction`, the MCP error redactor.
8. SQL the app builds from data: `apple/TablePro/Core/ChangeTracking/SQLStatementGenerator.swift`, `apple/TablePro/Core/Database/FilterSQLGenerator.swift`, `SQLEscaping.swift`, `DialectQuoteHelper.swift`, each driver's `quoteIdentifier`; on Linux `linux/crates/core/src/dml`, `linux/crates/core/src/filter/validate_raw_predicate.rs` and each driver's `dialect.rs`. A crafted table or column name that escapes quoting runs SQL with the user's privileges.
9. SSH and TLS: `apple/TablePro/Core/SSH/` (libssh2, host key prompts), `apple/Packages/TableProMacCore/Sources/TableProSSHConfig`, `linux/crates/ssh` (drives the system `ssh`, so watch for option injection from connection fields), `linux/crates/net/src/tls`.
10. Rendering of cell values: the out-of-process image renderer (`apple/TablePro/CLI/ImageRenderMain.swift`), `apple/TablePro/Core/Services/Formatting/PhpSerializeParser.swift`, the MongoDB shell's JavaScriptCore runtime.

Matter least: layout, theming and localization code, `linux/crates/test-fixtures`, `linux/crates/test-support`, `apple/TableProUITests`, `scripts/`, `.github/`, docs.

## How to exercise it

- Linux app: `cd /src/linux && meson devenv -C _build cargo test --locked -p <crate> [filter]`. Cargo runs offline. GTK widget tests need `xvfb-run -a dbus-run-session --` in front. Tests marked `requires docker` need a real database and cannot run here; for a driver bug, stand up a fake server on loopback in Rust or Python and point the driver at it.
- Swift: `cd /src/.oss-scanner/swift && swift test [--filter <suite>]`. This package holds the `apple/Packages/TableProCore` targets that compile on Linux, linked in from there, so a patch to them is a patch to the app:
  - `TableProSQLGrammar`: statement splitting and classification behind `ExternalStatementGate`, which MCP, AppleScript and the AI tools go through. A statement it misreads can carry a write past a read-only gate.
  - `TableProSQLiteCore`: the SQLite authorizer that denies `load_extension` and `fts3_tokenizer`.
  - `TableProLogRedaction`, `TableProCoreTypes`, `TableProDocumentPath`, `TableProJavaScriptText`.
  
  To exercise another target, add it to `.oss-scanner/swift/Package.swift` and link its folder the way the Dockerfile does. Most of the rest import Apple frameworks and will not compile.
- macOS-only code: give the input, the path through the code with file and line, and a failing test in the style of the nearest test target (`apple/TableProTests`, `apple/Packages/*/Tests`, Swift Testing) that we can run on a Mac.

## How we rate severity

- **Critical:** code execution, or SQL run in the user's session, triggered by a server, a database value, a file, a link or a web page with no step from the user beyond connecting or opening; saved passwords or tokens read without consent; a plugin or update installed without a valid signature.
- **High:** MCP authentication bypass, or a token running SQL beyond its scopes or allowlist; a link that connects to an attacker's server with saved credentials, or runs SQL, without its confirmation; secrets written to logs, CloudKit, AI requests or an unencrypted export; Verify CA, Verify Identity, VerifyFull or an SSH host key check that accepts the wrong certificate or key; memory corruption reachable from server or file bytes (Rust `unsafe`, Swift unsafe pointers, C interop).
- **Medium:** SQL injection through a crafted object name that needs the user to run a specific action on it; a bypass of the Safe Mode confirmation for a statement the user typed; data from one connection shown or sent under another.
- **Low:** denial of service from a server or file (hang, unbounded memory, a Swift trap or Rust panic); anything that needs a setting the UI already labels as unsafe.

## Anything to leave alone

- TLS "Required (skip verify)" on Apple and "Require" on Linux skip certificate checks by design.
- Pre-connect scripts, password commands, startup commands, SSH `Match exec` and the Beancount helper run what the user configured. Report them only when one arrives from a link, an import or sync without its consent prompt.
- `TABLEPRO_ALLOW_UNSIGNED_PLUGINS` works only in Debug builds. Built-in plugins skip the signature check because they ship inside the signed app.
- Bugs inside the prebuilt libraries in `apple/Libs` and inside third-party crates belong upstream, unless TablePro's use of them is the bug.
- Another process running as the same user, except through a path TablePro adds with its own gate (MCP tokens, the AppleScript statement gate, deep link confirmation).
- Missing hardening with no exploit path.

## Reports and patches

- One defect per report, with file and line, the input, the effect and a failing test.
- Patches follow the surrounding code. Rust: no `unwrap`, `expect` or `panic!` outside tests. Swift: tests in Swift Testing, in the existing test target.
