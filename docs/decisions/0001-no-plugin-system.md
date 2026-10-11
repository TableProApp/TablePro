# 0001: Database drivers are statically linked

- **Status**: Accepted
- **Date**: 2026-04-26

## Context

TablePro needs several database engines while keeping the connection, policy, and release boundaries easy to audit. Runtime-loaded drivers would add manifest validation, version negotiation, signing, discovery, and an additional trust boundary around code that handles credentials and network connections.

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
