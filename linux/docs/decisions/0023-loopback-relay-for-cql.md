# 0023: A loopback relay for the CQL client

- **Status**: Accepted
- **Date**: 2026-10-23

## Context

Every stream a driver opens comes from its `Transport`: a direct TCP dial, an SSH forward, or the tests' `FaultTransport`. An SSH forward is a Unix socket ([0013](0013-openssh-client-transport.md)), and so is a `FaultTransport` route.

The CQL client the driver uses, `scylla` 1.9, which ScyllaDB maintains for both ScyllaDB and Apache Cassandra, dials a TCP address itself. Its connection code takes a `SocketAddr` and nothing else (`connect_with_source_ip_and_port`), the hook that would hand it a stream is compiled only for its own tests, and the address it dials is also the name it gives rustls. It cannot reach a Unix socket, so it cannot reach a server through an SSH tunnel.

## Decision

Each scylla session dials a relay of its own on `127.0.0.1`, which carries every connection it accepts over a stream from `Transport::open`.

## Rationale

- Every byte still goes through the transport, so an SSH tunnel, the transport's own errors and the tests' faults reach the CQL driver as they reach the others.
- The port is the kernel's pick and lives as long as the session. The relay serves a connection only after `/proc/net/tcp` names this user as the connecting socket's owner, so another user on the machine cannot ride the tunnel through it.
- The driver checks the certificate against the name `NetworkTarget::tls_server_name()` gives, not against the relay's address scylla hands rustls.

## Consequences

- 0013's "no TCP port is opened on the machine" no longer holds for a CQL connection: a loopback port is open while it lives, served only to this user.
- The relay is Linux-only, through `/proc/net/tcp`, which the app's platform already is.
- A scylla release that takes a stream or a Unix socket removes the relay, and this ADR is then superseded.

## Alternatives considered

- **cdrs-tokio**, whose connection manager could take a stream of the driver's own: one maintainer and about a fiftieth of scylla's downloads on crates.io in October 2026, against the client a server vendor maintains.
- **A fork of scylla that takes a stream**: refused by [0005](0005-supply-chain-policy.md); `deny.toml` allows no git source.
- **The DataStax C++ driver through bindings**: a C library with its own TLS, against [0009](0009-crypto-provider-and-sources.md).
- **A CQL client written here**: the protocol, paging, prepared statements and topology are the work scylla already does and keeps secure.
- **SSH forwards to a TCP port**: 0013 moved away from them, and they would cover SSH only, not the transport's other routes.
