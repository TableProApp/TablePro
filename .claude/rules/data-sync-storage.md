---
paths:
  - "TablePro/Core/**/*Storage*.swift"
  - "TablePro/Core/**/*Sync*.swift"
  - "TablePro/Core/Database/**/*"
  - "Packages/TableProCore/Sources/TableProSyncTransport/**/*"
  - "CloudKit/**/*"
---

# Data, sync, and connection changes

Search `.agents/skills/tablepro-engineering/references/invariants-data.md` for CloudKit production fields and delete ordering, and `.agents/skills/tablepro-engineering/references/invariants-connections.md` for schema loading, refresh retention, cancellation, attempt generations, pooling, and persistence teardown. Protect user data and prove late-completion behavior with tests.

This rule adds domain constraints. It does not pick your workflow: `AGENTS.md` decides whether you are in `$fix-issue` or `$tablepro-engineering`, and you never load both.
