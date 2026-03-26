# Connection Sharing & Alternative Sync

Feature documentation for [#466](https://github.com/TableProApp/TablePro/issues/466) — enabling teams to share database connection configurations.

## Documents

1. [**prd.md**](prd.md) — Product Requirements Document: goals, user stories, success metrics
2. [**competitive-analysis.md**](competitive-analysis.md) — How 20+ database clients handle sharing, best-of-breed ideas
3. [**architecture.md**](architecture.md) — Technical design: data models, file format, integration points
4. [**epics.md**](epics.md) — Epic breakdown across 3 tiers with acceptance criteria
5. [**tasks.md**](tasks.md) — Granular task tracking with status, dependencies, and estimates
6. [**decisions.md**](decisions.md) — Architecture Decision Records (ADRs) for key design choices

## Tiers

| Tier | Scope | License | Target |
|------|-------|---------|--------|
| **Tier 1** | Export/import, drag-and-drop, copy-as-link | Free | MVP |
| **Tier 1** | Encrypted export with credentials | Pro | MVP |
| **Tier 2** | Linked folders, env var refs | Pro | Next |
| **Tier 3** | CLI, lockdown mode, secrets manager | Pro | Later |
| **Tier 3** | Clipboard auto-detection | Free | Later |

## Related Code

| Component | Path |
|-----------|------|
| Connection model | `TablePro/Models/Connection/DatabaseConnection.swift` |
| Connection storage | `TablePro/Core/Storage/ConnectionStorage.swift` |
| Keychain helper | `TablePro/Core/Storage/KeychainHelper.swift` |
| Deeplink handler | `TablePro/Core/Services/Infrastructure/DeeplinkHandler.swift` |
| URL formatter | `TablePro/Core/Utilities/Connection/ConnectionURLFormatter.swift` |
| URL parser | `TablePro/Core/Utilities/Connection/ConnectionURLParser.swift` |
| Welcome window | `TablePro/Views/Connection/WelcomeWindowView.swift` |
| Connection form | `TablePro/Views/Connection/ConnectionFormView.swift` |
| App file handler | `TablePro/AppDelegate+FileOpen.swift` |
| Sync engine | `TablePro/Core/Sync/CloudKitSyncEngine.swift` |
| Group/Tag storage | `TablePro/Core/Storage/GroupStorage.swift`, `TagStorage.swift` |
| SSH profile storage | `TablePro/Core/Storage/SSHProfileStorage.swift` |
