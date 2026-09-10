---
paths:
  - "TablePro/Core/**/*Storage*.swift"
  - "TablePro/Core/**/*Sync*.swift"
  - "TablePro/Core/Database/**/*"
  - "Packages/TableProCore/Sources/TableProSyncTransport/**/*"
  - "CloudKit/**/*"
---

# Data, sync, and connection changes

This path is a user-data boundary. Read the `### Invariants` section of `CLAUDE.md` and find the paragraphs that apply; `### Storage Patterns` in the same file says which store owns what.

The ones that bite most often on this path:

- **A synced CKRecord field must reach Production before anything writes it.** Both apps pin the container to Production and CloudKit only auto-creates fields in Development, so no build can create one. A record carrying an undeclared field is rejected whole, and with `isAtomic = false` the rest of the batch still saves, so the symptom is one record type silently never syncing. Follow the deploy sequence in the invariant and let a new `ConnectionSyncField` case stay `.unverified` until the schema snapshot is committed.
- **Persist before you notify.** `SyncChangeTracker.markDeleted()` runs after `saveConnections()`, never before, or a sync fired by the notification re-uploads the deleted record from the stale file.
- **A refresh never clears the cache it is refreshing.** Fetch first, then commit over the old value. Only enter `.loading` when there is no loaded content, signal an in-flight refresh separately, and never let a failed refresh replace good data.
- **Cancelling a connect does not stop the driver.** `Task.cancel()` is cooperative and cannot interrupt a blocking C call, so a cancelled attempt completes late. Validate the `ConnectionAttemptRegistry` generation before adopting a driver or tearing session state down. This area shipped the same bug four times.
- **A pooled metadata read assumes a second connection reaches the same database.** That is false for an embedded engine. Route every metadata read through `DatabaseManager.withMetadataDriver` so `supportsConnectionPooling` can apply.

Prove late-completion and cancellation behavior with a test. A silent wrong answer here looks exactly like an empty database.

This rule adds domain constraints and does not pick your workflow.
