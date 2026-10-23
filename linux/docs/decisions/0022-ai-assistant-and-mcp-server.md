# 0022: An AI assistant and a local MCP server

- **Status**: Accepted
- **Date**: 2026-10-23

## Context

The macOS app has an AI assistant, answered by a provider the user adds with their own key, and an MCP server on `127.0.0.1` that lets MCP clients use the saved connections without seeing a password. The Linux app had neither, and nothing said whether it would ([#3642](https://github.com/TableProApp/TablePro/issues/3642)).

Three things bear on both:

- **Privacy.** The README promised that TablePro reaches only the database servers and SSH hosts the user set up. An assistant sends prompts, and with them table names, columns and sometimes rows, to a provider.
- **Attack surface.** The roadmap turns down embedded scripting because it widens the attack surface. A server any local program can reach is a new way into the user's databases.
- **Write guard.** A client asking for a write is not the user asking for it. Safe Mode has levels and a confirmation dialog the user answers in the app, which a client's write can go through.

## Decision

The Linux app gets both: an MCP server bound to `127.0.0.1`, off until the user turns it on, with an External Clients level per connection; and an AI assistant, off with no provider until the user adds one, with an AI policy per connection.

## The MCP server

- It listens on `127.0.0.1` alone, never on another interface, and only while TablePro runs with **Preferences > MCP > Enable MCP Server** on. The port is a preference.
- Every request carries a bearer token, kept in the Secret Service, made on the first start and replaced from Preferences. Any program of any user on the machine can reach the port, so the token is what tells the user's own client apart. A request whose `Host` is not a loopback name, or that carries an `Origin`, is refused, so a web page cannot reach it through DNS rebinding.
- Each saved connection has an External Clients level, set in its connect dialog. **Blocked** hides it: it is not listed and every call naming it is refused. **Read Only**, the default and the level of every connection saved before the level existed, lets a client read the schema and the data. **Read & Write** also lets it write.
- A client reaches a connection only through the window that has it open, and `connect` opens it the way the picker does, with every prompt shown there. Passwords never leave the keyring.
- A read runs on a connection the engine holds read-only. A write runs only at Read & Write, never under Safe Mode Read-Only, and only after the user approves it in the connection's window, in Safe Mode's dialog with Cancel the default, whatever the Safe Mode level. One statement per call, or one batch on SQL Server, so what the user approves is all that runs.
- The protocol is the official Rust SDK, `rmcp`, over stateless Streamable HTTP.

## The AI assistant

- Off by default, with no provider until the user adds one.
- Anthropic, OpenAI and Ollama. Ollama goes through the OpenAI-compatible protocol, so any self-hosted server that speaks it works too.
- API keys in the Secret Service, as passwords are ([ADR 0004](0004-libsecret-secret-storage.md)).
- An AI policy per connection that keeps the connection's schema and rows out of every prompt.
- The README's Privacy section names the provider as a destination for what the assistant sends.

## Rationale

Users who query their databases from an AI client today run a second tool beside TablePro, with its own copy of their credentials. Through TablePro, a client gets the user's saved connections, the guards they set on each and the app's confirmation, and never a password. Off by default, local only, a token, a per-connection level and a confirmation for every write keep the new surface to what the user turns on.

The assistant sends data off the machine, so it starts with no provider and says where the data goes before the user adds one.

## Consequences

- TablePro opens a listening socket when the user turns the server on. The README's Privacy section says so.
- A client that speaks only stdio needs a bridge to Streamable HTTP; the server ships no stdio binary of its own.
- A client holding the token can read every connection that is not Blocked, as the user's login allows. The login's privileges are the guard on functions that read server files; Read Only stops writes, not those reads.
- A write from a client waits for the user. A client running unattended cannot write.
- The assistant's provider receives prompts with schema and rows of every connection whose policy allows it. The policy and the External Clients level are separate settings: one governs the assistant, the other MCP clients.
- Neither is a release criterion, so neither blocks the first release.

## Alternatives considered

- **Leave both out.** Users would keep a second tool with its own credentials, or the macOS app.
- **A stdio bridge binary, as the macOS app ships.** Another binary to package and a handshake file for the port, for clients that mostly speak HTTP already.
- **Writes without a confirmation at Read & Write.** A client acting on a prompt the user never saw could change data the user never chose to change.
- **The macOS app's per-client approvals and scoped tokens.** One token and the per-connection level cover a single user's machine; they can come later without changing what a connection's level means.
