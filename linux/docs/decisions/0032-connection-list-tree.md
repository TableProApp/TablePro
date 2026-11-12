# 0032: The connection list is the library's tree in a list view

- **Status**: Accepted
- **Date**: 2026-11-03

## Context

[Core 0006](../../../core/docs/decisions/0006-connection-library.md) gave the saved-connection list a group tree up to 3 levels deep, a manual order and an ordered favourites list. Its Consequences said the Linux app shows a group by its path, such as `Work / Staging`, wherever it lists groups, and makes new groups at the top. The picker was an `AdwPreferencesPage` with one `AdwPreferencesGroup` per path, and the window's tree built its groups from the paths of the connections in them. Neither could show an empty group, nest, follow the stored order, show favourites or take a drop. Two groups with one path, such as a top-level `Work / Staging` and Staging inside Work, read as one.

## Decision

The picker and the window's tree show the library as a tree in a `GtkListView` over a `GtkTreeListModel`, built from one `LibraryOutline` keyed by group and connection ids, and change it by drag and drop and by menus.

## Rationale

- **A list view, not boxed lists.** The HIG keeps boxed lists for "relatively small static lists" and sends large or dynamic ones to list views. `AdwPreferencesPage::add` takes only `AdwPreferencesGroup`, which cannot nest.
- **Ids, not paths.** A rename, a move or two groups with one path keep their own rows, and every menu and drop names its target by id.
- **One persistent node and child store per id.** `GtkTreeListModel` reads every child of a row it opens and folds a row taken out of its model, and `GtkListView` rebuilds its rows on each change, so a write changes only the stores whose ids changed, in one removal and one addition at most.
- **Favourites and Recent are sections**, a `GtkFlattenListModel` of flat models before the tree, as the macOS library lists them. A favourite has a row there and one in its group. The window's tree has no such sections: its connection rows hold the open sessions' schemas.
- **Every move has a menu item.** The HIG's editable lists ask for "move up" and "move down" items beside dragging, "required for accessibility purposes". Move to Group and Move Group To list every group by its path; drag and drop is the pointer's way to the same moves.
- **The outline refuses before the store does.** A drop or a menu move that the store would refuse, such as a group into its own subgroup or past 3 levels, shows no drop line and no menu item. A name taken in the new place is the store's error, worded in a toast.
- **Search stays a flat list** of the connections it finds, each naming its group's path, since a tree that kept every match's parents open would read every child of each.

## Consequences

- The picker's order is the library's. The recency order inside each group goes; the Recent section keeps the 5 connections opened last at the top, without the favourites.
- There is no sort mode, Recent switch, group colour or group icon in the Linux UI yet. Core 0006 leaves the first two to each app's settings.
- A duplicate lands right after its original.

## Alternatives considered

- **Nested `AdwExpanderRow`s in the boxed lists.** No indentation past the first level, no drop indicator, and the per-section filters cannot keep a match's parents.
- **Favourites as a group at the top of the tree.** It would mix a section that is not in the library into the tree's drop rules.
- **Paths as group identities.** Two groups with one path merge, and a rename folds the group.
