# 0001: Database drivers are statically linked

- **Status**: Accepted
- **Date**: 2026-04-26

## Context

BookiE needs several database engines while keeping the connection, policy, and release boundaries easy to audit. Runtime-loaded drivers would add manifest validation, version negotiation, signing, discovery, and an additional trust boundary around code that handles credentials and network connections.

## Decision

Every database driver is a Rust workspace crate under `crates/drivers/`. Drivers are compiled into the application and agent binaries and registered by their composition roots.

Adding an engine requires:

1. A crate under `crates/drivers/<engine>/`.
2. Implementations of the `tablepro-core` driver contracts.
3. Workspace membership and composition-root registration.
4. Maturity documentation and real-engine tests.
5. A new application release.

There is no runtime driver discovery, external driver manifest, registry service, or driver ABI.

## Rationale

Static registration keeps the full driver boundary type-checked. It also lets review, dependency scanning, policy integration, and release tests cover the exact code shipped in each binary.

The maintenance cost is predictable. A new driver increases compile time and binary size, but it does not create a second installation or update system.

## Consequences

Accepted:

- Third-party drivers require a fork or contribution.
- Adding a driver requires recompilation and release.
- Binary size grows with the compiled driver set.
- Drivers cannot be loaded or replaced while the app is running.

Gained:

- One Cargo graph defines the shipped implementation.
- Rust checks types across every driver boundary.
- Policy and audit integration can be verified before release.
- Driver dependencies are covered by the repository supply-chain checks.

## Alternatives considered

**WebAssembly components.** Rejected because database drivers need credentials, sockets, TLS, cancellation, and engine-specific libraries. Exposing those host capabilities would add complexity without removing the main trust boundary.

**Rust dynamic loading with a stable ABI layer.** Rejected because versioning and loading costs exceed the value for the current driver set.

**C ABI drivers.** Rejected because they would reduce type safety and make async, typed values, and errors harder to evolve.

**OSGi or JDBC plugin hosts.** Rejected for the same reason as a runtime ABI. A third-party bundle can return values and open connections outside the type-checked driver crates and outside release proof of [PolicyGuard](0016-governed-consumer-seam.md).

**Out-of-process JDBC or JSON-RPC driver agents.** Rejected. A sidecar process is another trust boundary around credentials and sockets, and it makes typed values and policy integration harder to prove in the shipped binary.

**In-process ODBC (`unixODBC`, `odbc-api`) for fetch performance.** Rejected (2026-10-07 grid-memory review). Columnar fetch does not bound memory when rows are collected into a `Vec`, and a generic ODBC layer conflicts with server-side cancellation ([ADR 0005](0005-server-side-cancellation.md)), native value preservation ([ADR 0007](0007-type-and-value-preservation.md)) and session ownership ([ADR 0008](0008-connection-and-session-ownership.md)). Revisit only for a named engine gap, as one scoped driver crate that meets the same contracts.

**Engine breadth by runtime bridge (Oracle, Cassandra, "100+ engines via JDBC").** Out of scope. Oracle and Cassandra are not planned drivers; a future engine arrives as a static driver crate under the rules above.

## Revisit conditions for a JDBC bridge

An optional JVM/JDBC bridge needs an amendment to this ADR before any code. The amendment must define a narrow exception, a list of approved engine, class and artifact profiles (no arbitrary JARs), a typed encoding for values (JSON-RPC alone is not lossless for temporal zones and precision or for native and nested values), and no bridge-local SQL-prefix classifier. [`PolicyGuard`](0016-governed-consumer-seam.md) stays the only consumer connection.

Sources: [grid memory and fetch plan](../archive/grid-memory-and-fetch-action-plan-2026-10-07.md), [external audit](../archive/external-audit-2026-10-06.md), [feature comparison history](../archive/feature-comparison-history-2026-10-23.md).
