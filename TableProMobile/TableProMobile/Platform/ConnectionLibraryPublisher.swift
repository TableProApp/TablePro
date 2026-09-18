import AppIntents
import Foundation
import os
import TableProModels
import WidgetKit

@MainActor
final class ConnectionLibraryPublisher {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LibraryPublisher")

    private let searchIndex: any ConnectionSearchIndexing
    private let writeWidgetItems: ([WidgetConnectionItem]) -> Void
    private let refreshShortcutParameters: () -> Void

    private var shortcutProjection: [SearchableConnection]?
    private var indexed: [SearchableConnection]?
    private var queued: [SearchableConnection]?
    private var replacing: Task<Void, Never>?

    init(
        searchIndex: any ConnectionSearchIndexing,
        writeWidgetItems: @escaping ([WidgetConnectionItem]) -> Void,
        refreshShortcutParameters: @escaping () -> Void
    ) {
        self.searchIndex = searchIndex
        self.writeWidgetItems = writeWidgetItems
        self.refreshShortcutParameters = refreshShortcutParameters
    }

    static func live() -> ConnectionLibraryPublisher {
        ConnectionLibraryPublisher(
            searchIndex: SpotlightConnectionIndex(),
            writeWidgetItems: { items in
                SharedConnectionStore.write(items)
                WidgetCenter.shared.reloadAllTimelines()
            },
            refreshShortcutParameters: {
                TableProShortcuts.updateAppShortcutParameters()
            }
        )
    }

    nonisolated static func widgetItems(for connections: [DatabaseConnection]) -> [WidgetConnectionItem] {
        connections
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { connection in
                WidgetConnectionItem(
                    id: connection.id,
                    name: connection.name.isEmpty ? connection.host : connection.name,
                    type: connection.type.rawValue,
                    sortOrder: connection.sortOrder
                )
            }
    }

    nonisolated static func searchableConnections(for connections: [DatabaseConnection]) -> [SearchableConnection] {
        connections
            .map(SearchableConnection.init(connection:))
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func publish(_ connections: [DatabaseConnection]) {
        writeWidgetItems(Self.widgetItems(for: connections))
        let searchable = Self.searchableConnections(for: connections)
        if searchable != shortcutProjection {
            shortcutProjection = searchable
            refreshShortcutParameters()
        }
        queued = searchable
        guard replacing == nil else { return }
        replacing = Task { await drainReplacements() }
    }

    func settle() async {
        await replacing?.value
    }

    private func drainReplacements() async {
        while let next = queued {
            queued = nil
            guard next != indexed else { continue }
            do {
                try await searchIndex.replaceConnections(with: next)
                indexed = next
            } catch {
                indexed = nil
                Self.logger.error("Spotlight replace failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        replacing = nil
    }
}
