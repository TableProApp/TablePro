# Fork baseline review: September 17, 2026

## Baseline and review limits

Fetched `origin` (`cozyGarage/TablePro`, historically called `fork`) and pulled
`linux` with `--ff-only`. Starting HEAD `32ce81f9c`; resulting HEAD
`e9bba1f5b24575b4eb959b492421ff50c9117063`. The working tree was clean before
pulling. No local commits were discarded. The earlier implementation snapshot is
already integrated in `6e22badc4`; do not cherry-pick it again.

Coverage: the latest 30 commits in `git log -30` traversal order, including the
merge and previously reviewed implementation commits. Reviewed change inventories
and targeted source/caller inspection, not every line of the vendored snapshots.
This is not a fresh release/security certification or a review of new TableProApp
upstream commits beyond the earlier pinned upstream review.

## Findings and actions

1. **Implementation and direct regression fixed, handshake fixture pending:** MongoDB's vendored SCRAM validator now
   uses a checked prefix comparison, so short or non-ASCII server nonces cannot panic.
   Direct validator tests cover prefix match, mismatch and a shorter server nonce;
   an actual hostile-server handshake fixture is still required before claiming
   end-to-end runtime verification.
2. **Resolved in the continuation:** development storage and Secret Service identity
   now share the build profile. Config, data, drafts, locks and credentials use the
   isolated development identity while production paths remain compatible.
3. **Read bound fixed, B4 race test pending:** session material now opens one handle,
   validates that handle and caps actual bytes read at 1 MiB. Test rotation during
   connection establishment: fingerprinting and connection assembly still load
   material separately.
4. **P2, fixed here:** the resource copy of the icon predates the 0.1.3 packaged
   artwork. Removed the duplicate and aliased the canonical packaged SVG from the
   resource manifest. Compiled the resource and compared extracted bytes with the
   package source. App ID and resource path stay unchanged.
5. **Remaining verification gap:** driver tests for excessive SCRAM iteration caps
   inspect source strings. They detect removal of named lines, not bypass of the
   authentication path. Keep those checks, but require an actual excessive-iteration
   handshake rejection before calling hostile-server handling verified.
6. **Partially resolved build gap:** Cargo enables GNOME 50 after the shortcut and
   calendar API migration. A temporary Meson/Ninja environment completed a development
   build and staged install with validated `.Devel` metadata. A real Flatpak build and
   package installation remain B1 gates.

## Lessons to preserve in 0.2

- `72238a6c2`: formatting moved into core; adjacency and newline semantics are
  checked, with real PostgreSQL result comparisons as an independent oracle.
  Never rely solely on testing a lexer against itself.
- `310329a98`, `72238a6c2`: declared SQL types do not establish runtime value
  types. Reject incompatible values both at widget binding and when accepting
  queued edits. Preserve rebind and stale-event tests during lossless migration.
- `b121b2abb`, `72238a6c2`: INTERVAL/INET/CIDR/LSN are supported without false NULL;
  extrema and malformed byte corpora matter. Do not restore the earlier explicit
  unsupported-type failures for these now-supported values.
- `2c5499947`: session reuse depends on secret/key/CA material as well as saved
  connection fields. Retire changed sessions without invalidating already-issued
  references. Preserve fail-closed keyring/read failures and auth-hop restrictions.
- `471f11301`, `72238a6c2`: a negative TLS test must first prove a valid connection
  and then assert a certificate-related failure. Any-error assertions hide broken
  infrastructure and do not establish endpoint identity.
- `74f6aef16`, `aefb33b51`: mutation checks exposed symbolic constants and tests
  missing one condition branch. Assert concrete boundaries and both outcomes.
- `72238a6c2`: isolated ignored tests must have executable runner registrations;
  evidence carries SHA, dirty state, toolchain and raw logs. Use existing runners.
- `e9bba1f5b`, `a69cef734`, `43eab0a15`: test actual package contents and command
  aliases, and makepkg source discovery, not only manifest text. Keep Debian's
  deliberate `tablepro` package name separate from Arch's `bookie` transition.
- `4234d67a3`, `7b02bb920`: a platform bump includes builder images, native
  libraries and removed APIs. Do not re-enable GNOME 50 flags mechanically.
- `788c47f39`: the manual connection lab is useful acceptance infrastructure;
  its existence is not evidence that all interactive scenarios passed.

## Continuation packets

The review started at `e9bba1f5b`; security closure landed in `2a3b8c7` and the
GNOME 50/development baseline in `399fb5b`. Record a fresh actual SHA as later
implementation lands. Preserve existing
policy/audit/MCP, paths, keyring identity, additional drivers and pinned patches.

1. **Security closure before broad migration:** reproduce malformed SCRAM nonce
   handling and bounded material reads, then fix at shared boundaries. Use focused
   tests followed by transport/agentd and authentication fixtures. Exclude broad
   transport redesign. Terra medium for bounded fixes; Sol review for sessions.
2. **B1 completion:** retain Rust 1.98, SQLx 0.9/system SQLite, crypto, GNOME 50,
   development isolation and Meson work already integrated. Qualify the GNOME 50
   Flatpak and package builders. No automatic dependency patch removal. Sol medium.
3. **B2 ownership and migration:** connect explicit stores and private profile
   paths/keyring schema, then Tasks/GSettings/history migration and shutdown.
   Preserve distinct persistence error/recovery contracts rather than merging
   writers solely because they look alike. Require migration/rollback, malformed
   files and durable shutdown tests. Sol medium.
4. **B3/B4:** lossless values across all eight drivers and every consumer, then
   integrated session/OpenSSH contracts. Carry the new affinity, formatter,
   material-rotation and authentication regressions throughout. Sol high, with
   independent architecture review for transport/audit boundaries.
5. **B5/B6/B7:** editor/file workflows, read-only PostgreSQL catalog, then new
   exact-candidate qualification. These remain authorized and incomplete.

Original A1–A4 implementation is in the baseline; A5 manual package/Wayland,
upgrade/rollback and uninterrupted soak evidence remain separate. Do not downgrade
0.1.4 to fulfill historical 0.1.1 wording. No publication is authorized by this review.

## Verification in this pass

- Arch candidate archive/rejection fixture: passed.
- Ignored-test inventory and isolated registrations: passed.
- `cargo +1.98 test --manifest-path linux/Cargo.toml -p tablepro-core --lib sql_format`:
  16 passed. Running Cargo from the repository root without an explicit toolchain
  selected host Rust 1.93.1 and correctly failed MSRV; use the pinned toolchain.
- GResource compilation and extraction using Python GI: passed; embedded SVG is
  byte-identical to the canonical packaged icon.
- Debian fixture: blocked by missing `dpkg-deb` on this host. No package installation
  or host dependency changes were performed.
- Full workspace, database/TLS fixtures, GTK, optional DuckDB, install/rollback and
  soak were not rerun. Earlier ledger evidence applies only to its recorded trees.

After the review, the exact combined security/platform tree passed preflight,
`scripts/ci-local.sh full`, `cargo deny check`, and all 19 GTK safety scenarios
against the staged Meson development install. A real Flatpak build, package
install/upgrade/rollback, driver-service fixtures and candidate soak remain open.

## Complete 30-commit inventory

| Commit | Subject |
| --- | --- |
| `e9bba1f5b` | fix(linux): feed makepkg Arch sources from SRCDEST |
| `7074572da` | docs(linux): name GitHub Release files in architecture tree |
| `43eab0a15` | docs(linux): document 0.1.4 Linux versions and Debian aliases |
| `a69cef734` | fix(linux): install bookie in the Debian 0.1.4 package |
| `72238a6c2` | fix bug, add test, prepare release 0.1.4 |
| `1c3c34634` | Merge remote-tracking branch 'fork/linux' into linux |
| `2c5499947` | fix(linux): close session rotation and unbounded SCRAM holes |
| `32ce81f9c` | docs(linux): record the upstream test-suite parity pass in the sprint ledger |
| `788c47f39` | update step 8, ongoing |
| `471f11301` | test(drivers): verify TLS endpoint identity |
| `7b02bb920` | docs(linux): record the deferred GNOME 50 platform bump in the sprint ledger |
| `4234d67a3` | build(linux): keep CI buildable — add libsqlite3-dev, defer the GNOME 50 platform bump |
| `aefb33b51` | docs(linux): note the BookiE rename plan in CLAUDE.md; extend mutation CI to ssh and driver-redis |
| `6e22badc4` | wip: snapshot other agent's in-progress BookiE work before pulling linux |
| `77db37f9d` | fix(ssh): bump russh to 0.62.7 for hostile-host client CVEs (#12) |
| `c6d6aae18` | fix(linux): 0.1.3 icon and drop unused rkyv 0.7 (#11) |
| `43b6f8f41` | docs(linux): add Arch Omarchy 0.1.2 install steps (#10) |
| `74f6aef16` | test(ssh,driver-redis,app): close mutation-testing gaps in socket path, CLI escaping, and truncation limits |
| `310329a98` | fix(datagrid): keep binary TEXT cells out of the edit buffer (#9) |
| `3f4d586fd` | build(linux): bump MSRV and CI toolchain to Rust 1.98 |
| `b121b2abb` | fix(driver-postgres): decode interval inet and lsn as text (#5) |
| `b20fa5621` | Test/ssh hardening (#7) |
| `346ba96ed` | test(ssh): cover known_hosts IO failure, connect-error mapping, and socket path limit (#6) |
| `35db741e8` | docs(linux): record upstream test-suite parity plan |
| `d2102c036` | docs(linux): record BookiE delivery sprint and implementation evidence |
| `52acc06ff` | feat(linux): prepare BookiE 0.1.1 identity and immutable candidate packaging |
| `c6e55076c` | feat(linux): add generation-safe Jump to Column navigation |
| `df3122716` | fix(linux): guard SQL formatting and preserve dialect execution boundaries |
| `b84f3f8af` | fix(linux): preserve complete drafts and serialize durable settings writes |
| `d3e529422` | feat(linux): import upstream dialect-aware script planning |
