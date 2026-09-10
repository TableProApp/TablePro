---
paths:
  - "TablePro/Core/AI/**/*"
  - "TablePro/Core/MCP/**/*"
  - "docs/external-api/**/*"
  - "docs/features/ai-assistant.mdx"
---

# AI and MCP changes

This path is a security boundary: it decides what a model, a tool call, or a paired client is allowed to do with the user's databases and credentials.

Trace and preserve, every time:

- Provider disclosures and consumer-subscription behavior, so the user always knows which service their query text reaches.
- Tool authorization, safe mode, and confirmation state. Read-only stays the default, and a destructive operation stays behind an explicit confirmation.
- Token scope, connection allowlists, query limits, timeouts, session recovery, and audit logging. Widening any of them is the change, not a side effect of one.

Ask what this lets a user or a paired client do that they could not do before, and answer it in writing. A new surface here is a new trust boundary.

Run `Skill(security-review)` over the diff before the commit for any change to authorization, scope, allowlists, or a destructive operation. Update the matching page under `docs/external-api/` in the same change, because that page is the contract external clients are written against.

This rule adds domain constraints and does not pick your workflow.
