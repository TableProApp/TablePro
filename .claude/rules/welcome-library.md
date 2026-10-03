---
paths:
  - "TablePro/Views/Welcome/**/*"
  - "TablePro/ViewModels/WelcomeViewModel*.swift"
  - "Packages/TableProCore/Sources/TableProConnectionLibrary/**/*"
---

# Welcome connection list

- **The outline is built from storage, never a cache of it.** Every edit is a storage read-modify-write (`ConnectionStorage.mutateConnections`, `moveConnections`, `GroupStorage.mutateGroup`, `moveGroups`) followed by `rebuildOutline()`. Saving a record the view model holds overwrites changes made elsewhere.
- **A row's identity is its section plus its id (`LibraryRowID`)**, so a favorite has one row under Favorites and another inside its group.
- **A reload waits while a drag or an inline rename is in flight** (`isDragging`, `renameSession`) and runs in `applyPendingReloadIfNeeded()`; reloading under either ends the drag or loses the typed name.
