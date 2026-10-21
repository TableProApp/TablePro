//
//  DashboardTilesView.swift
//  TablePro
//

import SwiftUI

struct DashboardTilesView: View {
    @ObservedObject var board: DashboardTileBoard

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "Saved Queries"), systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
                addMenu {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .help(String(localized: "Add Saved Query"))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Add Saved Query"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if board.tiles.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(board.tiles) { tile in
                            tileView(tile)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server-dashboard-saved-queries")
        .task { await board.loadCatalogIfNeeded() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Add a saved query to watch its result here.")
                .foregroundStyle(.secondary)
            addMenu {
                Text("Add Saved Query")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 10)
    }

    private func addMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            if board.catalog.favorites.isEmpty {
                Button(String(localized: "No Saved Queries")) {}
                    .disabled(true)
            } else {
                DashboardSavedQueryMenuItems(
                    catalog: board.catalog,
                    folderId: nil,
                    isAdded: { board.contains(favoriteId: $0) },
                    add: { board.add(favoriteId: $0) }
                )
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func tileView(_ tile: DashboardTile) -> some View {
        let index = board.tiles.firstIndex { $0.id == tile.id } ?? 0
        return DashboardTileView(
            tile: tile,
            title: board.title(for: tile),
            state: board.state(for: tile.id),
            canMoveEarlier: index > 0,
            canMoveLater: index < board.tiles.count - 1,
            actions: DashboardTileView.Actions(
                setInterval: { board.setInterval($0, for: tile.id) },
                moveEarlier: { board.moveEarlier(tile.id) },
                moveLater: { board.moveLater(tile.id) },
                remove: { board.remove(tile.id) },
                dropTile: { droppedId in
                    guard board.tiles.contains(where: { $0.id == droppedId }) else { return false }
                    board.move(droppedId, onto: tile.id)
                    return true
                }
            )
        )
    }
}

struct DashboardSavedQueryMenuItems: View {
    let catalog: DashboardSavedQueryCatalog
    let folderId: UUID?
    let isAdded: (UUID) -> Bool
    let add: (UUID) -> Void

    var body: some View {
        ForEach(catalog.folders(in: folderId)) { folder in
            Menu(folder.name) {
                DashboardSavedQueryMenuItems(catalog: catalog, folderId: folder.id, isAdded: isAdded, add: add)
            }
        }
        ForEach(catalog.favorites(in: folderId)) { favorite in
            Button(favorite.name) { add(favorite.id) }
                .disabled(isAdded(favorite.id))
        }
    }
}
