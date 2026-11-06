# 0014: A new connection starts on the TLS mode the engine's own client starts on

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

The apps started a new connection on three different modes: Linux on Verify full wherever the driver offered it, Windows on Disable, and macOS on each driver's own default. On Linux a new connection to a local PostgreSQL or MySQL without TLS failed on the first connect, and the error offered no fix. The core had no mode for TLS when the server offers it, so neither app on the core could start where psql and mysql start.

What each engine's own client starts on, read from its documentation and source in November 2026:

| Engine | Client | Starts on |
|---|---|---|
| PostgreSQL | libpq, `sslmode=prefer` ([libpq-connect](https://www.postgresql.org/docs/current/libpq-connect.html), `fe-connect.c` on REL_18_STABLE) | TLS when the server offers it, plain otherwise; the certificate is not checked |
| MySQL | `mysql` 8.4 and 9.x, `--ssl-mode=PREFERRED` ([connection options](https://dev.mysql.com/doc/refman/8.4/en/connection-options.html)) | The same; a handshake that fails is an error |
| MariaDB | the 11.4 client and Connector/C 3.4 (MDEV-31855, MDEV-31856, MDEV-31857) | TLS required and checked, where a self-signed certificate passes on a fingerprint derived from the password |
| SQL Server | ODBC Driver 18, Microsoft.Data.SqlClient 4 and later, SSMS 20 and later, sqlcmd on ODBC 18 ([encryption and certificate validation](https://learn.microsoft.com/en-us/sql/connect/ado-net/encryption-and-certificate-validation)) | `Encrypt=Mandatory` with `TrustServerCertificate=false`: TLS with the chain and the name checked. go-sqlcmd alone encrypts only the login and trusts any certificate |
| MongoDB | mongosh ([connection string options](https://www.mongodb.com/docs/manual/reference/connection-string-options/)) | Plain for `mongodb://`; TLS with the certificate checked for `mongodb+srv://` |
| Redis, Valkey | redis-cli, valkey-cli ([redis-cli](https://redis.io/docs/latest/develop/tools/cli/)) | Plain unless `--tls` or `rediss://` |
| Cassandra, ScyllaDB | cqlsh (`DEFAULT_SSL = False` in `cqlshmain.py`) | Plain |
| ClickHouse | clickhouse-client (`ConnectionParameters.cpp`) | Plain, and secure on its secure port 9440 or a ClickHouse Cloud host |

## Decision

A new connection starts on the mode the engine's own client starts on for what the user typed. The core holds it: `TlsCapabilities::default_mode` and `tls_ports` per driver, and `DriverCapabilities::new_connection_tls(port, options)` for the rule, which every app reads. The core gains `TlsMode::Prefer` for the engines that negotiate TLS inside their protocol. Every TLS failure that a change of mode fixes offers Change Encryption.

| Engine | A new connection starts on |
|---|---|
| PostgreSQL | Prefer |
| MySQL, MariaDB | Prefer |
| SQL Server | Verify full |
| MongoDB | Disable, or Verify full with a DNS seed list |
| Redis | Disable |
| Cassandra, ScyllaDB | Disable |
| ClickHouse | Disable, or Verify full on its HTTPS ports 8443 and 443 |
| SQLite, DuckDB | No TLS |

## Rationale

- A user who types the host, port and login they give psql, mysql, sqlcmd or mongosh expects to connect where that client connects. A default stricter than the engine's client fails on the most common server, a local one, with a setting the user never chose. A default looser than it gives away a check the user already had.
- The standard is each engine's own client, not one mode for every engine, because the engines differ. PostgreSQL and MySQL ask for TLS inside their protocol and can go on without it. The others decide TLS by the port before the first byte, so their clients start plain and turn TLS on only when told.
- Prefer is what libpq and mysql call it and what they do: ask for TLS, go on in the clear when the server has none, and not check the certificate. tokio-postgres 0.7.18 (`SslMode::Prefer`, `connect_tls.rs`) and sqlx-mysql 0.9.0 (`MySqlSslMode::Preferred`, `connection/tls.rs`) do the same. A Prefer that checked the certificate would fail on every self-signed server where psql connects.
- MariaDB departs from its own client. One driver serves both servers and tells them apart only after it connects, and sqlx has no fingerprint check, so Verify full would fail on every stock 11.4 server, which makes its own self-signed certificate. Prefer encrypts against each of them.
- SQL Server starts on Verify full because ODBC Driver 18, Microsoft.Data.SqlClient 4 and SSMS 20 all check the certificate by default. go-sqlcmd's looser default is the exception among Microsoft's clients.
- ClickHouse's HTTP interface has no secure native port, so its HTTPS ports stand where clickhouse-client's 9440 does. A ClickHouse Cloud service takes HTTP only over TLS on 8443, which the port rule already covers.

### What Prefer protects

- Prefer stops a passive listener when the server offers TLS. It does not stop an active attacker, who can answer that the server has no TLS or present any certificate. PostgreSQL rates prefer as "Maybe" against eavesdropping and "No" against a man in the middle, and keeps it as libpq's default only for backward compatibility ([libpq-ssl](https://www.postgresql.org/docs/current/libpq-ssl.html)). MySQL calls VERIFY_CA and VERIFY_IDENTITY a better choice than the default.
- So the apps say what it does where it is chosen. On Linux the Encryption row's subtitle under Prefer reads "Encrypted if the server offers TLS, otherwise not. The server certificate is not checked.", in the short, plain and neutral form the GNOME HIG's Writing style asks for. On Windows the mode reads "Preferred, any certificate". Verify full is one choice away, and an import names a connection looser than a new one.

## Consequences

- The UI keeps the mode on the engine's default until the user picks one, as the port follows the driver: a driver switch, a DNS seed list and a port that serves only TLS move it. A saved connection keeps the mode it was saved with, so a later edit never weakens it.
- `ServerRefusedTls` offers Change Encryption. Under Disable, Redis, MongoDB, Cassandra and ClickHouse check a plain login the server dropped with a TLS handshake of their own, sent with no credential, and report a server that completes it as `ServerRequiresTls`, as SQL Server already did. The other way round, a Redis without TLS reads the hello as a command and waits for its newline, so a handshake that times out is checked with a plain `PING` and reported as `ServerRefusedTls` when the server answers it.
- Foreign import keeps another app's Preferred as Prefer where the engine offers it, and the nearest stronger mode where it does not. A connection URL's `sslmode=prefer`, `sslmode=allow` and `ssl-mode=PREFERRED` read as Prefer, `mongodb+srv://` as Verify full, and a URL that trusts any certificate (`TrustServerCertificate`, `tlsAllowInvalidCertificates`, `tlsInsecure`) as Require.
- libpq retries in the clear after a TLS handshake that fails; tokio-postgres does not, and neither do sqlx and the mysql client. A PostgreSQL server that agrees to TLS and then fails the handshake fails the connect.
- The macOS app keeps its own defaults until its connection form moves onto the core ([ADR 0010](0010-macos-on-the-core.md)). They match this rule except for SQL Server, which it starts on Preferred (FreeTDS `encryption=request`).
- The connection list stores `prefer` without a new file version, as it does `strict`: no released build reads the file yet ([Linux ADR 0033](../../../linux/docs/decisions/0033-no-compatibility-with-pre-release-states.md)).

## Alternatives considered

- **Verify full for every engine.** It is the strongest mode, and what Linux started on in development, but it fails on a local server and on every self-signed one, where the engine's own client connects.
- **Disable for every engine,** as Windows had. It reaches a local server, and sends the login in the clear to a server that offers TLS.
- **Require for PostgreSQL and MySQL.** It fails on a server without TLS, where psql and mysql connect.
- **A default in each app.** Three apps drifted into three defaults. The core is the one place every app reads.
