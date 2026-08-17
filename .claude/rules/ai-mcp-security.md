---
paths:
  - "TablePro/Core/AI/**/*"
  - "TablePro/Core/MCP/**/*"
  - "docs/external-api/**/*"
  - "docs/features/ai-assistant.mdx"
---

# AI and MCP changes

Trace provider disclosures, consumer-subscription behavior, tool authorization, safe mode, confirmation state, token scope, connection allowlists, query limits, timeouts, session recovery, and audit logging. Preserve read-only defaults and require `$cross-model-review` for authorization or destructive-operation changes.

This rule adds domain constraints. It does not pick your workflow: `AGENTS.md` decides whether you are in `$fix-issue` or `$tablepro-engineering`, and you never load both.
