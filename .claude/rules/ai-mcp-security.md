---
paths:
  - "TablePro/Core/AI/**/*"
  - "TablePro/Core/MCP/**/*"
  - "docs/developers/**/*"
  - "docs/integrations/mcp-clients.mdx"
  - "docs/integrations/raycast.mdx"
  - "docs/features/ai-assistant.mdx"
---

# AI and MCP

This path decides what a model, a tool call or a paired client may do with the user's databases and credentials.

- **Preserve** provider disclosures, tool authorization, Safe Mode and confirmation state, token scope, connection allowlists, query limits, timeouts and audit logging. Read-only stays the default, and a destructive operation stays behind an explicit confirmation.
- **Widening any of them is the change itself**, never a side effect: state in the PR what a user or a paired client can now do that it could not before.
- **Run a security review of the diff** before committing any change to authorization, scope, allowlists or a destructive operation.
- **Update the matching page under `docs/developers/` in the same change**; external clients are written against it.
