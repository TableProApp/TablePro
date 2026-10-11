# 0006: A driver panic is contained, not trusted away

- **Status**: Accepted
- **Date**: 2026-09-18

## October 3 implementation/privacy note

The unwind containment decision remains accepted. The source currently logs the caught payload, and the default panic hook may also expose it. “Logs only” below describes the original routing; it does not make arbitrary payload text safe or override the no-secret/SQL logging rule. [The consistency review](../archive/architecture-consistency-review-2026-10-03.md#remaining-source-risks) defines the redaction and headless retirement follow-ups. Keep unwind enabled while addressing them.

## Context

Drivers decode whatever the server sends. A hostile, compromised, or merely buggy server can drive a decoder into a state its author did not anticipate, and some of our dependencies answer that with a panic rather than an error. The SQL Server driver is the concrete case: `tiberius` panics inside its codec on input it cannot parse, and we consume it as a pinned git dependency, so we cannot fix it in our own code.

Nothing in the application caught that. There was no `catch_unwind`, no `JoinError` inspection, and no panic hook anywhere in `app`, `mcp`, or `agentd`. A panic inside a Relm4 command killed that task silently. The component that dispatched it was waiting for a message that would now never arrive, so the interface kept showing "Loading" forever with no error, no log entry tying the hang to a cause, and no audit outcome for an operation that had already recorded its intent.

The workspace lints deny `unwrap`, `expect` and `panic!` in our own code. They say nothing about a dependency's code, which is where this panic originates.

## Decision

`PolicyGuard` catches the unwind at every call it forwards and converts it into a `DriverError`:

- A read becomes `DriverError::Internal`.
- A write becomes `DriverError::OperationOutcomeUnknown`.

The guard then reports the fault through an optional `ConnectionFaultSink` installed by whoever owns the connection. `app::services::database_service` implements that sink and wakes the connection monitor, which replaces the connection rather than waiting for the next ping.

Returned errors, audit fields and UI messages must omit the raw panic payload.
The current logger sends it to `tracing`, and the default hook can also print it;
this violates the shared logging privacy rule and remains an implementation gap
tracked by [the release audit](../archive/release-audit-2026-10-03.md#small-release-tasks).
Keep operation identity and containment while removing arbitrary payload text.

## Rationale

`PolicyGuard` is the right place because the repository already guarantees that every connection exposed to a consumer passes through it, and because it forwards every `Connection` method explicitly. One boundary there covers the GTK app, MCP, and `agentd` at once, and no future call site can forget to opt in. The alternative chokepoints, the individual Relm4 command sites, are 27 places that each had to remember.

Converting to an error rather than swallowing the panic means the existing audit path handles it with no new plumbing: it sees an ordinary `Err`, records the required terminal state, and poisons governed writes exactly as it does for any other ambiguous write failure.

The read and write split is not cosmetic. When a driver stops in the middle of a write, the client genuinely does not know whether the server applied it. `OperationOutcomeUnknown` already carries that meaning in this codebase, and it already drives the poisoning behaviour that such an outcome requires. Reporting a write panic as a plain failure would be a claim we cannot support.

Replacing the connection is a separate necessity from reporting the error. A panic midway through a protocol exchange leaves unread bytes and unverified state on the wire, so the next statement on that connection cannot be trusted. Waiting for the 30-second ping was not sufficient, and not only because of the delay: a desynchronised connection can still answer a ping. The fault path therefore skips the ping and reconnects.

## Consequences

The application survives a panicking driver with an honest error, a logged cause, a correct audit record, and a fresh connection, instead of a permanent silent hang.

Containment is not a repair. A caught panic means a dependency reached a state its author did not expect, and we resume on a new connection without knowing why. The log line is the only evidence, so it must stay useful.

`catch_unwind` requires the unwinding panic strategy. Setting `panic = "abort"` in a release profile would silently disable this entire boundary, so that setting must not be introduced without replacing this mechanism.

The sink is opt-in through `PolicyGuard::with_fault_sink` rather than a required `GuardContext` field. That keeps the change additive for the eleven places that build a `GuardContext`, at the cost of making it possible to build a guard that converts panics without replacing the connection. `mcp` and `agentd` do exactly that today, deliberately: they have no connection monitor to wake.

## Alternatives considered

**Fork the dependency and remove the panics.** This is what upstream `TableProApp/TablePro` did for `tiberius`. It is the real fix for the specific library, and it remains worth adopting, but it does not generalise: the next driver with the same habit reintroduces the hang. Containment and a fork solve different halves, and the fork is now an upgrade rather than a prerequisite.

**A process-level hook for duplicate diagnostics.** Rejected in the original
decision. `catch_unwind` does not suppress the default hook. Privacy treatment
of that hook is still required; the rejection of duplicate diagnostics does not
justify printing arbitrary payloads.

**Wrap each Relm4 command site.** Rejected. It covers only the GTK app, leaves MCP and `agentd` exposed, and relies on every future author remembering.

**Mark the connection unhealthy without replacing it.** Rejected. Health is advisory in this design; nothing prevents the next statement from using a connection whose protocol state is unverified.
