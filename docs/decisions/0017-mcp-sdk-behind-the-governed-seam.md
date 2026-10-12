# 0017: Adopt the official Rust MCP SDK behind the governed seam

- **Status**: Proposed
- **Date**: 2026-10-12

## Context

`crates/mcp/src/server.rs` is 996 lines. About half of it is protocol plumbing: JSON-RPC framing for stdio and streamable HTTP, protocol-version negotiation, `initialize`, `tools/list`, `tools/call`, hand-written tool descriptions and JSON schemas, loopback binding and an `Origin` check. The other half is the product: token scopes, connection allowlists, approval, masking, audit, and cancelling an operation when the HTTP caller disconnects. Those live in `McpBridge` and `tablepro-policy`, not in the transport.

The Model Context Protocol changes (the SDK now targets the 2026-07-28 specification), and the maintainer wants room to add resources, prompts and other MCP features later without growing the hand-written layer.

A pilot built outside the repository (`rmcp` 3.5.1, Apache-2.0, minimum Rust 1.88) showed:

- A server over an in-memory pipe negotiated protocol 2025-06-18, listed a tool whose JSON Schema (draft 2020-12) was generated from a Rust struct, returned a tool result, and returned a normal `isError` result for bad arguments.
- It ships stdio and streamable-HTTP server transports, is built on `tokio`, `http` and `tower`, and the HTTP server feature does not require `axum` (we use `axum` 0.8, which it also targets).
- Its own test suite includes the case we depend on: when a stateless streamable-HTTP client disconnects while a tool handler is still running, the per-request cancellation token fires so the handler can cancel cooperatively.
- OAuth, `reqwest` and `jsonwebtoken` are optional features we would leave off.

## Decision

Replace the protocol, transport and tool-schema layer of `crates/mcp` with `rmcp`. Keep everything that carries a safety decision:

- `McpBridge`, token scopes, connection allowlists, approval, masking and audit stay in our code and stay the only way a tool reaches a database ([ADR 0016](0016-governed-consumer-seam.md)). A tool handler holds a `PolicyGuard` connection and nothing else.
- Token and `Origin` checks and loopback-only binding move into `tower` middleware in front of the SDK's streamable-HTTP service. Our token is still presented the way existing clients present it, so existing setups keep working.
- Tool input types become Rust structs with generated schemas; the hand-written `tool_schema` JSON goes away.

The migration is staged behind the existing MCP tests. The adoption is complete only when every current MCP test passes against the new layer, including the refusal without a token, the bad-token refusal, the disconnect-aware cancellation with no execution after a disconnect during approval, and the shutdown test.

## Rationale

The protocol layer is maintained by the project that defines the protocol, and tracks the specification for us. The code we keep is exactly the code that is specific to BookiE and security-critical. The SDK's schema generation removes a class of drift between a tool's description and its real arguments.

## Consequences

Accepted:

- A new dependency tree to review under `deny.toml` and the supply-chain job. Only the `server`, `macros`, `schemars` and the two server transports are enabled.
- `rmcp` is at 3.x and changes between majors; we pin and upgrade deliberately.
- Our token is not an HTTP `Authorization` bearer in all cases today; the middleware must preserve current behaviour rather than silently switching clients to OAuth.

Gained:

- Protocol compliance and future MCP features (resources, prompts, elicitation) come from the SDK.
- Roughly 400 to 500 lines of transport code leave `crates/mcp`.
- Schemas are generated from the same types the handlers read.

## Alternatives considered

- **Keep the hand-written server.** Works today; every new MCP feature and spec change is ours to write and to get wrong.
- **Run an MCP server as a separate process.** Rejected for the same reason as [ADR 0001](0001-no-plugin-system.md): another trust boundary around credentials and sockets.
- **Adopt the SDK's OAuth support now.** Out of scope; it can follow once the transport is in place.
