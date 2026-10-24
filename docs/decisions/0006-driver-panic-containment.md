# 0006: A driver panic is contained, not trusted away

- **Status**: Accepted
- **Date**: 2026-09-18
- **Clarified**: 2026-10-15 for the dependency. The workspace uses the crates.io `tiberius` 0.13 release, not a pinned git dependency. The decision is unchanged.

### Clarification (2026-10-20)

The blast-radius count query and `PolicySession::close` now use the guarded panic boundary, resolving [#880](https://github.com/cozyGarage/BookiE/issues/880). The statement below that a future call site cannot forget to opt in describes the required architecture; composition roots and internal direct calls still need review and regression coverage.

## Context

Drivers decode whatever the server sends. A hostile, compromised, or merely buggy server can drive a decoder into a state its author did not anticipate, and some of BookiE's dependencies answer that with a panic rather than an error. The SQL Server driver is the concrete case: `tiberius` panics inside its codec on input it cannot parse. The original decision used a pinned Git revision; the workspace now uses crates.io `tiberius` 0.13. This boundary remains necessary until the panic is fixed in a reviewed release or maintained patch.

At the time, nothing in the application caught that. There was no `catch_unwind`, no `JoinError` inspection, and no panic hook anywhere in `app`, `mcp`, or `agentd`. A panic inside a Relm4 command killed that task silently. The component that dispatched it was waiting for a message that would now never arrive, so the interface kept showing "Loading" forever with no error, no log entry tying the hang to a cause, and no audit outcome for an operation that had already recorded its intent.

The workspace lints deny `unwrap`, `expect` and `panic!` in BookiE's own code. They say nothing about a dependency's code, which is where this panic originates.

## Decision

`PolicyGuard` catches the unwind at every call it forwards and converts it into a `DriverError`:

- A read becomes `DriverError::Internal`.
- A write becomes `DriverError::OperationOutcomeUnknown`.

The guard reports the fault through an optional `ConnectionFaultSink` installed by the connection owner. `app::services::database_service` wakes its monitor to replace the connection immediately. `agentd` marks its cached session retired; the next session acquisition removes and replaces it. The MCP bridge has no connection cache or monitor of its own and relies on its provider's lifecycle.

Returned errors, audit fields and UI messages must omit the raw panic payload.

## Rationale

`PolicyGuard` is the right place because the repository already guarantees that every connection exposed to a consumer passes through it, and because it forwards every `Connection` method explicitly. One boundary there covers the GTK app, MCP, and `agentd` at once, and no future call site can forget to opt in. The alternative chokepoints, the individual Relm4 command sites, are 27 places that each had to remember.

Converting to an error rather than swallowing the panic means the existing audit path handles it with no new plumbing: it sees an ordinary `Err`, records the required terminal state, and poisons governed writes exactly as it does for any other ambiguous write failure.

The read and write split is not cosmetic. When a driver stops in the middle of a write, the client does not know whether the server applied it. `OperationOutcomeUnknown` already carries that meaning in this codebase, and it already drives the poisoning behaviour that such an outcome requires. Reporting a write panic as a plain failure would assert an outcome the client cannot establish.

Replacing the connection is a separate necessity from reporting the error. A panic midway through a protocol exchange leaves unread bytes and unverified state on the wire, so the next statement on that connection cannot be trusted. Waiting for the 30-second ping was not sufficient, and not only because of the delay: a desynchronised connection can still answer a ping. The fault path therefore skips the ping and reconnects.

## Consequences

The application survives a panicking driver with an honest error, a correct audit record, and a fresh connection, instead of a permanent silent hang.

Containment is not a repair. A caught panic means a dependency reached a state its author did not expect, and operation resumes on a new connection without establishing the original cause.

The app and `agentd` install a panic hook that always withholds the payload. `TABLEPRO_DEBUG_PANICS=1` enables a backtrace without restoring Rust's payload-printing hook; `RUST_BACKTRACE=1` also requests one. Both modes retain the source location and stack frames while keeping the panic message out of logs and stderr. [#666](https://github.com/cozyGarage/BookiE/issues/666) records the installed-launch investigation steps. `PolicyGuard` separately catches driver panics and logs only the operation and payload byte count; returned errors withhold the payload. These hooks do not cover arbitrary panics in other processes or code that does not install the hook.

The guard also contains panics from synchronous driver status checks. A panic while checking cancellation support reports that cancellation is unavailable; a panic while checking session health retires that guarded session permanently, even if the driver later reports it healthy. When a fault sink is installed, both checks report the connection as unusable.

`catch_unwind` requires the unwinding panic strategy. Setting `panic = "abort"` in a release profile would silently disable this entire boundary, so that setting must not be introduced without replacing this mechanism.

The sink remains opt-in through `PolicyGuard::with_fault_sink` rather than a required `GuardContext` field. That keeps construction additive, at the cost of allowing a guard to convert panics without reporting the unusable connection. The GUI wakes a monitor immediately; agentd retires its cached session for replacement on the next acquisition. The MCP bridge owns no cached connection lifecycle.

## Alternatives considered

**Fork the dependency and remove the panics.** This addresses the specific library defect, but it does not generalise: another driver can introduce the same failure mode. Containment and a dependency fix solve different parts of the problem. The guard remains necessary even if the affected dependency is patched.

**A process-level hook for duplicate diagnostics.** Rejected in the original decision. `catch_unwind` does not suppress the default hook. Privacy treatment of that hook is still required; the rejection of duplicate diagnostics does not justify printing arbitrary payloads.

**Wrap each Relm4 command site.** Rejected. It covers only the GTK app, leaves MCP and `agentd` exposed, and relies on every future author remembering.

**Mark the connection unhealthy without replacing it.** Rejected. Health is advisory in this design; nothing prevents the next statement from using a connection whose protocol state is unverified.

**A crash report that includes the panic payload.** Rejected. A raw panic message can carry SQL, secrets or values. Any future diagnostic feature keeps secret and value redaction and bounded private retention ([upstream movement review](../archive/upstream-linux-movement-2026-10-18.md), section 7).
