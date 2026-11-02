# Architecture Decision Records

Decisions that hold for every platform that builds the shared core: its crates, their contracts and how each app reaches them. A decision only one app makes goes in that app's folder, such as `linux/docs/decisions/`.

The format, the statuses and how a later ADR changes an earlier one follow [the Linux decisions' README](../../../linux/docs/decisions/README.md). An ADR here that changes a Linux ADR updates only that ADR's Status line and its row in the Linux index.

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-shared-core.md) | One shared Rust core, a native UI per platform | Accepted | The UI-free crates move to `core/crates` and build on Linux, Windows and macOS; each app keeps a native UI and passes its platform services in. |
| [0002](0002-connection-library.md) | The connection library holds a group tree, manual order and favourites | Accepted | Groups form a tree by id, connections and groups carry an explicit order, favourites are one ordered list; version 2 group names become top-level groups. |
