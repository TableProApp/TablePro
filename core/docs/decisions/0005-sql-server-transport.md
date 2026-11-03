# 0005: SQL Server on tiberius everywhere, with Kerberos added and ODBC as a Windows option

- **Status**: Accepted
- **Date**: 2026-11-02

## Context

The SQL Server driver runs on tiberius 0.13.0 from crates.io, with GSSAPI behind its `kerberos` feature (MIT Kerberos on Linux; on macOS libgssapi-sys links the system's GSS framework, measured 2026-11-03) and `winauth` on Windows ([sql-server.md](../../../linux/docs/drivers/sql-server.md)). On Windows, users expect what Microsoft's own clients give them: Kerberos through SSPI, Entra ID sign-in, Always Encrypted and MARS.

The Windows spike of 2026-11-02 ran tiberius 0.13.0 (features `tds80`, `winauth`, `native-tls`) and ODBC Driver 18.7.1.1 (through `odbc-api` 29.3.0) against SQL Server 2022 Express 16.0.1000.6. SQL Server installs on x64 only, so the run used a GitHub-hosted `windows-2025` runner (image 20261021.299.1, run 41381600680), with a self-signed certificate trusted in `LocalMachine\Root` and then the server's Force Strict setting on. Each probe read `auth_scheme`, `encrypt_option` and `protocol_version` back from `sys.dm_exec_connections`.

| Mode | tiberius 0.13.0 | ODBC Driver 18.7.1.1 |
|---|---|---|
| SQL login | Pass | Pass |
| Integrated, current account | Pass, NTLM | Pass, NTLM |
| TLS, TDS 7.4 | Pass | Pass |
| `Encrypt=strict`, TDS 8.0 (`protocol_version=0x08000000`) | Pass, with SQL login and with NTLM | Pass, with SQL login and with NTLM |
| Server with Force Strict | Strict connects, TDS 7.4 refused | Same |
| Kerberos | None on Windows: winauth 0.0.5 asks SSPI for the `NTLM` package. Unix only, through GSSAPI | Yes per its docs. The runner is not in a domain, so both fell back to NTLM |
| Entra ID | A token the app brings (`AuthMethod::AADToken`) | Integrated, Interactive, managed identity, service principal, password, or a token |
| Always Encrypted | No | `ColumnEncryption=Enabled` |
| MARS | No: prelogin always sends `mars: false` | Yes |

## Decision

tiberius stays the SQL Server client on every platform, a fork of it adds SSPI Negotiate so Windows gets Kerberos and is offered upstream, the core gets Entra ID tokens itself, and on Windows an optional connection type runs over an ODBC Driver 18 for SQL Server the user already installed, for Always Encrypted, while TablePro never bundles that driver.

## Rationale

- **tiberius passes every mode the runner could test**, in Rust, on every platform, and it is the client the core already runs and tests on SQL Server 2017 to 2025.
- **The Kerberos gap is small and local.** On Windows, `AuthMethod::Integrated` builds winauth's `NtlmSspiBuilder` (`src/client/connection.rs`, lines 589 to 620). `flush_sspi` (`src/tds/stream/token.rs`, lines 244 to 263) expects a server token every round, but Kerberos with mutual auth can finish on the server's reply with no client token, so it needs a variant that returns either the next token or the login. The SPN `MSSQLSvc/host:port` is already built (`src/tds/context.rs`). The patch is an SSPI wrapper of about 150 to 250 lines over `AcquireCredentialsHandleW("Negotiate")` and an `InitializeSecurityContextW` loop, about 60 to 100 changed lines in `connection.rs` and `token.rs`, and `windows-sys` in place of winauth 0.0.5. Estimated at 2 to 4 days with a test domain (unverified).
- **A fork first.** `prisma/tiberius` is active again but releases in bursts: 0.13.0 on 2026-09-25, and 0.12.3 before it on 2024-07-19, with 48 open issues.
- **Entra ID in the core.** tiberius takes a token, so the core gets one itself, and every platform offers the same sign-in methods without a Microsoft client library.
- **Always Encrypted needs ODBC.** No Rust client has column encryption. ODBC Driver 18 does, so Windows users who have it installed can use it.
- **Never bundled.** msodbcsql18's license, read from the 18.7.1.1 MSI, lets us redistribute it, but restriction c(ii) forbids distributing it so that "any part of it becomes subject to any license that requires that the distributable code ... be disclosed or distributed in source code form". TablePro is AGPL-3.0. It is also a per-machine install: the DLL lands in System32 and registers as an ODBC driver, which needs admin rights and a UAC prompt.

## Consequences

- The driver builds against the fork until upstream takes the patch. `allow-git` in `deny.toml`, empty today, gains the fork, and the no-fork rule of [Linux ADR 0016](../../../linux/docs/decisions/0016-driver-contract-v2.md) no longer holds for tiberius.
- CI proves only the NTLM fallback. Kerberos needs an Active Directory test domain, which no GitHub-hosted runner has.
- The core builds tiberius with `default-features = false` and `tds73`, so `Encrypt=strict` needs the `tds80` feature and a strict TLS mode in the driver. The runner used `native-tls` (SChannel). The core uses `rustls`, since native-tls is banned ([Linux ADR 0009](../../../linux/docs/decisions/0009-crypto-provider-and-sources.md)), so the TLS cases run again on rustls.
- No MARS: a connection keeps one request in flight, as it does today.
- tiberius words a failed strict handshake as "unexpected EOF during handshake" or "failed to fill whole buffer" on native-tls, and as "tls handshake eof" on rustls, where ODBC names the handshake. In each case the server closes before sending a byte, so the driver asks it again, without credentials, and reports `ServerRefusedStrict` or `ServerRequiresStrict` only when it still refuses the opening the login used and answers the other.
- SQL Server on Linux takes strict TLS from 2025, which `network.forcestrict` can require. 2022 CU14 on Linux closes a strict login (measured 2026-11-03, rustls, Docker), where 2022 on Windows takes it.
- The ODBC connection type is Windows only and shows when "ODBC Driver 18 for SQL Server" is installed. The user installs it and accepts Microsoft's terms.
- SQL Server has no Arm64 build. Arm64 developers and CI need a remote or x64 server. A `windows-2025` runner installs Express in about 3 minutes.

## Alternatives considered

- **ODBC Driver 18 as the default on Windows.** It has every mode, but it is a per-machine install with admin rights that we cannot bundle, and tiberius already passes the common modes.
- **Bundling msodbcsql18.** Its license and the AGPL, as above.
- **Microsoft.Data.SqlClient 7.1 in the Windows app.** It has every mode, but it is .NET, outside the core, and no other platform would get it.
- **tiberius's `sspi-rs` feature.** It is Unix only and NTLM only (`src/client/auth.rs`).
- **Waiting for upstream.** No release cadence to wait on.
