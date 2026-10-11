# PostgreSQL release fixture

Deterministic PostgreSQL environment for the Phase 3 release gate. Run it from the workspace root:

```bash
./scripts/test-postgres-release.sh
```

The script generates materials, builds and starts the containers, waits for each path, and runs
agentd SSH/mTLS tests, the `tablepro-release-tests` suite, and a GTK saved-mTLS connection scenario.
The Rust suites run with `--include-ignored --test-threads=1`. Set
`TABLEPRO_FIXTURE_KEEP_UP=1` to leave the containers running after the suite.

## Requirements

Docker with Compose v2, `openssl`, `ssh-keygen`, `dbus-run-session`,
`gnome-keyring-daemon`, `secret-tool`, `xvfb-run`, and Python 3 with `pyatspi`.

## Topology

| Service | Role |
|---|---|
| `db` | PostgreSQL 16 with TLS enabled and the network alias `db.tablepro.test`. No published port. |
| `bastion` | OpenSSH server with a fixed host key and one public-key user, `tunnel`. No published port. |
| `toxiproxy` | Publishes the only host entry points: API `8474`, database path `5433`, bastion path `2223`. |

The database is reachable from the host only through Toxiproxy or through the bastion, so tests can
cut either path and observe reconnect behavior.

## Materials

`generate-materials.sh` writes `materials/`, which is not tracked:

- `ca.crt` / `ca.key`: fixture certificate authority
- `server.crt` / `server.key`: server certificate for `CN=db.tablepro.test` with
  `subjectAltName=DNS:db.tablepro.test,DNS:localhost`
- `other-ca.crt`: unrelated authority for unknown-CA rejection
- `client.crt` / `client.key`: client identity accepted by the dedicated mTLS role
- `rotated-client.crt` / `rotated-client.key`: second valid identity for rotation checks
- `wrong-client.crt` / `wrong-client.key`: client identity signed by the unrelated CA
- `ssh_host_ed25519_key`: bastion host key
- `client_ed25519_key`: tunnel user key

Regenerate with `./generate-materials.sh --force`. The runner script points `XDG_CONFIG_HOME` at
`state/config` and clears the fixture-local `known_hosts` first, so a regenerated host key does not
trip the SSH host-key mismatch check and the developer's own `known_hosts` is untouched.

## Scenarios covered

- `VerifyFull` succeeds against a hostname the certificate names
- `VerifyFull` rejects an address the certificate does not name
- `VerifyFull` and `VerifyCa` reject an unrelated certificate authority
- An SSH tunnel reaches a database that publishes no port
- `VerifyFull` through a socket-forwarded SSH tunnel verifies the original database hostname
- `VerifyFull` through SSH rejects a service identity the certificate does not name
- `VerifyFull` over a TCP-forwarded tunnel fails instead of verifying the local dial address
- A server-enforced client-certificate role accepts valid saved mTLS credentials directly and
  through SSH, rejects missing or untrusted client identities, and accepts rotated credentials
- The GTK app opens a saved mTLS connection and queries the fixture database; agentd exercises
  saved mTLS directly and over its saved SSH route and rejects an untrusted identity
- Read-only denies a data-changing CTE and an administrative function
- Batch and interactive rollback leave no rows behind
- Activity templates run, and the blocking-lock query reports a contended row
- Direct and SSH reconnect produce usable sessions

Server-confirmed cancellation and timeout are covered by
`cargo test -p tablepro-driver-postgres --test integration`.

The separate `scripts/test-driver-tls.sh` fixture verifies MySQL mTLS directly and through SSH,
including missing/untrusted identities and certificate rotation.
