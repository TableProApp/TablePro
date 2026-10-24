# BookiE product overview

## Purpose

BookiE is a native Linux database client for local database work. It provides saved connections, optional SSH transport, database browsing, SQL editing, and guarded access for both the desktop application and the local `bookie-agentd` MCP process.

Every shipped feature works without an account, license key, subscription, paid tier, or remote entitlement check. Database and SSH credentials use the system Secret Service. Database operations from the GUI, MCP, and agent process use the same policy and audit boundary.

## Product constraints

- Native GTK4 and libadwaita interface on Linux.
- Database drivers are linked at build time and implement shared Rust contracts.
- The GUI and MCP consumers do not receive raw driver connections.
- SQL parameters are bound, identifiers are dialect-quoted, and untrusted input is validated at the boundary.
- Unsupported values and uncertain operation outcomes remain explicit; the client does not silently turn them into NULL or success.
- The application does not include a hosted service, account system, browser UI, or runtime driver plugin host.

## Users and workflows

The [personas](docs/personas.md) describe the main usage contexts. The common workflow is to open a saved connection, browse or query a database, inspect exact returned values, and make changes through the application's policy and audit path. An MCP client can use `bookie-agentd` with token scopes and a connection allowlist; these controls complement rather than replace SQL policy.

## Capability and delivery status

The [architecture](ARCHITECTURE.md) describes crate boundaries and data flow. The [capability review](docs/capability-review.md) records current technical limits. The [0.2.0 completion status](docs/bookie-0.2-sprint.md), [backlog](docs/backlog.md), and [known limitations](docs/known-limitations.md) own delivery status, selected work, and user-visible gaps respectively. Those pages are the source for changing implementation status; this overview states product constraints only.

## Product outcomes

- A local user can connect and run a governed query without creating an account.
- Every database handle issued to a GUI, MCP, or agent consumer is policy-guarded.
- Operations retain explicit outcomes. Required audit records are written when policy requires them; Local or Dev policy can allow a human write after audit-intent failure, in which case that write may not be recorded.
- Supported database values follow each consumer format’s documented type contract. SQL NULL, empty values and unsupported values are kept distinct where the format can represent them; text-based exports use documented markers when they cannot.
