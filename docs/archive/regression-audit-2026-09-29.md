# Regression audit, 2026-09-29

Branch: `linux`. Starting revision: `f142d3fea`. This review examines recent B3
value fixes, their consumer paths, test selection and enforcement, then runs the
broader regression layers. It is not a claim that every input or database type
has been covered. Existing PostgreSQL inet-array work and its documentation were
present at the start and retained.

## Findings and corrections

| ID | Severity | Evidence before correction | Correction and permanent regression |
| --- | --- | --- | --- |
| R1 | Data correctness | Importing formula-safe `'-0.12345678901234567890123456789` returned rounded Decimal `-0.1234567890123456789012345679`. Ordinary input already refused this precision. | Use `Decimal::from_str_exact` in the shared formula-marker path. `value_contract_formula_safe_decimal_import_rejects_excess_precision` crosses raw/sanitized forms and two excessive-scale values; existing valid negative-decimal and scale tests remain. |
| R2 | Import correctness | Default binary CSV export could not be imported: empty blob `\x` failed on row 3 with `NotBytes`. | Accept the exporter’s `\x` prefix in the shared binary parser. Core round-trip covers all four delimiters, NULL, empty bytes and all 256 byte values. Real SQLite import asserts plan values, stored values, storage classes, lengths and terminal audit count. Existing `0x`, `0X` and bare hex support remains. Negative parser cases cover odd hex, non-hex and Unicode. |
| R3 | Validation correctness | The change-contract runner accepted ignored/measured tests and two summaries for an exact regression. All three negative subcases failed before correction. | Require one complete summary, matching names/counts and no ignored/measured/failed tests. Nonzero process exit remains failure. |
| R4 | Validation correctness | The isolated runner accepted a wrong name, repeated output, an ignored count and the first registered test’s output for every registration. Four new tests failed before correction. | Reuse the same strict named-test evidence parser as the value and change-contract runners. Six executable fake-Cargo regressions cover invalid output, nonzero exit, incomplete registration execution and successful execution of every matching name. |
| R5 | Mutation coverage | PostgreSQL’s scheduled mutation file list omitted `decode.rs`; seven of that module’s tests lacked the `value_contract` filter prefix. | Include the module in the job; include its units in the filter; add independent BIT/VARBIT byte-boundary/padding, INET/CIDR header/prefix and PG_LSN half/length assertions. A workflow regression pins all four decoder modules. The initial local measurement exposed MACADDR/MACADDR8 dispatch assertions that only called the private helpers; their successful cases now test dispatch too. |
| R6 | Required checks | The full gate omitted the function-size check used by preflight. | Run the existing checker in the full gate too; pin that call with a workflow-contract test. |
| R7 | Structure and baseline failures | PostgreSQL integration was 1821 lines; MySQL integration was 1269 against a 1206 ceiling; SQL Server library was 1235 against a 1200 soft limit. | Move PostgreSQL and MySQL value scenarios into modules under `tests/support/`; move SQL Server units into `src/tests.rs`. Keep the existing integration target and fixture ownership. A name inventory confirms every preexisting test was retained. Remove the two now-unnecessary file-size baselines. |
| R8 | Build hygiene | Strict Clippy rejected the MySQL session’s nested success guard and an unused app-test trait import. The bounded-call guard rejected new app-parser fixture calls. | Collapse the equivalent guard, remove the unused import, and use controlled metadata/write calls with a 60-second deadline in the affected parser fixtures. |
| R9 | Certificate-test quality | Wrong/no-authority cases used `is_err()`, allowing unrelated connection failures to satisfy the assertion. Hostname cases relied on error text. | Reuse a trusted connect/ping/close control, then require a TLS error or explicit certificate-verification reason. SQLx exposes MySQL rustls certificate failures through its I/O/internal error path. Cover VerifyCa and VerifyFull for wrong authorities on all five TLS fixture drivers and missing authorities where supported. |
| R10 | Ungated regressions | Three PostgreSQL policy session tests, the MCP MongoDB Extended JSON round trip and the app numeric-parser server test stayed ignored in normal tests and were absent from hosted selections. The generated ledger invented `tablepro-driver-tests` and `tablepro-driver-src` packages. | Select MCP/policy targets in the driver gate; register the app test with the exact-test runner and an `app-server` layer in the GTK fast job and local release gate. Derive ledger package/target from Cargo manifests. A contract test pins these selections and ledger entries. |
| R11 | GTK execution evidence | A real widget passed, but Mesa diagnostics interleaved into its unfinished stdout line and made the strict parser reject the execution. | Capture child stdout and stderr separately in the isolated runner; retain both, parse only test stdout. A fake-Cargo regression confirms stderr cannot alter the execution evidence. |

The production corrections are at shared parsing boundaries used by CSV import
planning. No driver-specific workaround or new dependency was introduced.
Seventeen new named tests were added: six Rust tests and eleven Python tests. Renamed
and moved tests are not counted as new coverage.

The documentation now reflects the app’s library test target, the actual Debian
testing CI container and required native libraries. The conflicting Ubuntu 25.10
compatibility labels were removed from the README and packaging guide.

## Review matrix

| Area | Review performed | Proof and limitations |
| --- | --- | --- |
| Recent PostgreSQL decoders | Read binary dispatch, bit/network/MAC/LSN/interval decoders, array length and element handling, NULL/Undecodable dispatch and parameter refusal. | New units assert exact expected strings and malformed neighboring lengths. Existing server oracles compare native text/wire and consumer results. Supported scalar behavior is distinct from deliberate refusal. |
| CSV import/export | Trace export text, formula sanitization, type classification, exact decimal parsing, byte parsing, row mapping, plan construction and policy-guarded SQLite batching. Inspect callers across core/app/driver tests. | R1 and R2 reproduced missing consumer contracts. Tests assert type as well as value, exact precision, storage and audit outcomes. CSV does not universally recover every original type. |
| Shared scalar corpus | Inspect parameter/SQL round trips and comparison helpers. | Float comparisons use bits, Decimal comparisons preserve rendered scale, text tests preserve Unicode and parameter order. Engine-specific casts and deliberate exclusions remain explicit. |
| Policy, MCP, daemon | Review bulk-insert denial/budget/audit tests and daemon controlled-method/session tests; include their unit and sandbox suites. | Existing allowed/denied, scope, approval, cancellation, timeout and durable audit regressions supply execution evidence. The TLS fixture also covers SQL Server certificate modes. This pass does not add a new threat model or prove every policy statement shape. |
| Persistence and SSH | Include corruption/recovery, process concurrency, known-host, authentication, cancellation and transport tiers. | Fixture results are recorded below; tests need real sockets and services. A sandbox socket refusal is an environment failure, not a product failure. |
| GTK | Review app test target ownership and controlled parser fixture calls; run isolated widgets/keyring and installed automation where prerequisites permit. | The app is now a library plus launcher; documentation calling it binary-only was stale. Xvfb evidence does not certify native Wayland or installed upgrade/rollback. |
| CI and harness | Inspect exact-test selection, Cargo artifacts, execution evidence, ignored-test registration, local gates and mutation file filters. | Eleven added Python regressions include real subprocess fixtures for the isolated runner. The layer catalog remains the entry point; zero selected value contracts and failed processes cannot pass. |

## File layout

- `crates/drivers/postgres/tests/integration.rs` owns the PostgreSQL test target
  and fixtures; `tests/support/value_contracts.rs` owns the extracted scenarios.
- MySQL uses the same target/support split for temporal, SQL-mode and native-value
  contracts. Support modules are compiled by the integration target, not selected
  as extra Cargo targets.
- SQL Server’s `src/tests.rs` is declared under `#[cfg(test)]`; production stays in
  `src/lib.rs`, `session.rs` and `zoned.rs`.
- `scripts/rust_test_evidence.py` owns named Rust execution evidence. Its callers
  select/build/run tests and retain their own reports; the helper parses output.
- Tests for runners stay in `scripts/tests/`; executable layer definitions stay
  in `scripts/test-layers.json`. Generated ignored-test links were refreshed.

## Verification

Execution results and source hashes are recorded in
[evidence/2026-09-29-regression-audit/validation.json](evidence/2026-09-29-regression-audit/validation.json).
Reports under `target/quality/` describe this dirty working tree, not a published
commit or hosted CI result. Failed initial checks remain in that directory.

The first full run stopped at a stale ignored-test inventory, then exposed size,
bounded-call and Clippy failures. A later sandbox run could not bind MongoDB’s
local test socket (`EPERM`), so the gate was rerun with permitted socket access.
One run’s shell failed after its tests passed because its script changed while
running; that run is not counted as a gate pass. Subsequent runs use stable
scripts and preserve their actual exit status.

The final full gate passes formatting, strict Clippy, file/function size and
bounded-operation guards, 59 Python harness tests, 1551 workspace passing Rust
executions and 1139 sandbox passing Rust executions. These counts include
overlapping tiers and subprocess executions; they are not a unique-test or
coverage percentage.

The corrected isolated widget runner executes all five registered tests. The
strengthened TLS fixture passes all 35 tests, and the exact app numeric-parser
server test passes. The final combined report passes every selected layer,
including 180 driver, MCP, policy, socket and SSH test executions. The PostgreSQL
release fixture passes 54 tests; Secret
Service executes all seven registrations. Installed GTK automation passes 27
scenarios through the copied release binary under Xvfb. The retained reports
show failed initial layers alongside successful reruns; an aggregate failed
report is never presented as an aggregate pass.

The optional DuckDB driver passes 28 unit/integration tests, and the GTK app
builds successfully with `--features duckdb`. The final supplemental report
records focused change tests, workflow lint, packaging contracts and the keyring
rerun separately from the default workspace gate.

## Mutation results

| Measurement | Result | Evidence directory under `target/quality/` |
| --- | --- | --- |
| Core import byte/formula-decimal functions | 3 caught, 1 unviable, no missed/timeouts; exit 0 | `2026-09-29-core-import-mutants/mutants.out/` |
| Initial PostgreSQL binary-text decoder selection | 78 caught, 6 missed; exit 2 | `2026-09-29-postgres-binary-mutants/mutants.out/` |
| Final PostgreSQL binary-text decoder selection | 73 caught, no missed/unviable/timeouts; exit 0 | `2026-09-29-postgres-binary-mutants-final/mutants.out/` |

The initial two MAC dispatch deletions revealed a unit-test gap: the valid-case
assertions called private decoders. The assertions now call binary dispatch.
Four other survivors were equivalent redundant guards:

- `byte_length > 0` versus `>= 0`: entering that branch requires
  `bit_length % 8 != 0`, which already implies positive payload length.
- INET header length `< 4` versus `<= 4`: exactly four bytes cannot contain a
  valid IPv4 or IPv6 payload, so later validation refused either path.
- IPv4/IPv6 length guards versus `true`: conversion to `[u8; 4]` or `[u8; 16]`
  rejects the same wrong lengths before constructing an address.

The redundant guards were removed. Slice destructuring checks the header;
array conversion checks the address. This preserves malformed-input refusal
and eliminates equivalent branches without mutation exclusions. The new full
selection generates 73 mutations and catches all of them. Interval formatting
is outside this local selection; the hosted job includes the whole module.

The core unviable mutation tries to return `Value::default()`, but `Value` does
not implement Default. It is not a caught mutation or behavioral evidence.
Mutation measurements use scratch copies and separate target directories; they
never alter the working checkout or share the fixture builds’ target directory.

Before-fix reproductions are retained beside the validation manifest:
[decimal](evidence/2026-09-29-regression-audit/decimal-before.txt),
[binary CSV](evidence/2026-09-29-regression-audit/binary-before.txt),
[isolated runner](evidence/2026-09-29-regression-audit/isolated-before.txt), and
[change-contract runner](evidence/2026-09-29-regression-audit/change-contracts-before.txt).

## Remaining coverage and acceptance

- Native PostgreSQL enum/enum-array and multirange metadata blockers remain in
  the existing value-contract ledger. Refusal coverage is not native support.
- BSON scalar kinds represented by identical text remain ambiguous in generic
  exports. Collection-wide heterogeneity beyond metadata/page samples remains open.
- SQL Server Kerberos/KDC qualification and lossless recovery of inexact legacy datetime ticks
  remain separate gaps; another driver’s green suite cannot close them.
- CSV empty text/NULL ambiguity, configurable lossy export options, locale decimal
  formats, unsupported native types and spreadsheet application re-import still
  require explicit format choices or further contracts. Binary NULL/empty cases
  added here use an ID column so CSV blank-record handling cannot erase a row.
- Line coverage and broad mutation survivor triage are separate measurements.
  Targeted mutation results apply only to their named files/functions and filters.
- The dependency-advisory tier was not executed: `cargo-audit` is not installed.
  Dependency checks remain separately gated by Linux Security CI.
- The first full harness lacked `dpkg-deb` and skipped that contract. A separate
  run using an extracted temporary package passed its positive and negative cases.
  Package contracts still do not certify installation or upgrade.
- Installed Arch/Wayland, Debian/GNOME, package upgrade/rollback and exact-candidate
  soak remain the sprint’s operator acceptance gates. No release is published.
