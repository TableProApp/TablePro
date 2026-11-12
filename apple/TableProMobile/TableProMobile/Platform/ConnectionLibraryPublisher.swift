import AppIntents
import Foundation
import os
import TableProLogRedaction
import TableProModels
import WidgetKit

// The index, the widget file and the shortcut parameters all outlive the process, so each is
// rewritten only when what it holds differs from the library, not at every launch.
@MainActor
final class ConnectionLibraryPublisher {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LibraryPublisher")
    static let publishedShortcutsKey = "com.TablePro.publishedShortcutProjection"

    private let searchIndex: any ConnectionSearchIndexing
    private let readWidgetItems: () -> [WidgetConnectionItem]
    private let writeWidgetItems: ([WidgetConnectionItem]) -> Void
    private let refreshShortcutParameters: () -> Void
    private let defaults: UserDefaults
    private let build: String

    private var indexed: [SearchableConnection]?
    private var queued: [SearchableConnection]?
    private var replacing: Task<Void, Never>?

    init(
        searchIndex: any ConnectionSearchIndexing,
        readWidgetItems: @escaping () -> [WidgetConnectionItem],
        writeWidgetItems: @escaping ([WidgetConnectionItem]) -> Void,
        refreshShortcutParameters: @escaping () -> Void,
        defaults: UserDefaults,
        build: String = ""
    ) {
        self.searchIndex = searchIndex
        self.readWidgetItems = readWidgetItems
        self.writeWidgetItems = writeWidgetItems
        self.refreshShortcutParameters = refreshShortcutParameters
        self.defaults = defaults
        self.build = build
    }

    static func live(defaults: UserDefaults = .standard) -> ConnectionLibraryPublisher {
        ConnectionLibraryPublisher(
            searchIndex: SpotlightConnectionIndex(),
            readWidgetItems: { SharedConnectionStore.read() },
            writeWidgetItems: { items in
                SharedConnectionStore.write(items)
                WidgetCenter.shared.reloadAllTimelines()
            },
            refreshShortcutParameters: {
                TableProShortcuts.updateAppShortcutParameters()
            },
            defaults: defaults,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        )
    }

    // The widget only opens connections, so one this device cannot open would take a slot and end in an alert.
    nonisolated static func widgetItems(for connections: [DatabaseConnection]) -> [WidgetConnectionItem] {
        connections
            .filter { !MacOnlyConnection.isMacOnly($0) }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { connection in
                WidgetConnectionItem(
                    id: connection.id,
                    name: connection.name.isEmpty ? connection.host : connection.name,
                    type: connection.type.rawValue,
                    sortOrder: connection.sortOrder,
                    glyph: LibraryGlyph.connectionGlyph(type: connection.type, iconName: connection.iconName)
                )
            }
    }

    nonisolated static func searchableConnections(for connections: [DatabaseConnection]) -> [SearchableConnection] {
        connections
            .map(SearchableConnection.init(connection:))
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func publish(_ connections: [DatabaseConnection]) {
        let items = Self.widgetItems(for: connections)
        if items != readWidgetItems() {
            writeWidgetItems(items)
        }
        let searchable = Self.searchableConnections(for: connections)
        let digest = SearchableConnection.digest(of: searchable, build: build)
        if digest != defaults.data(forKey: Self.publishedShortcutsKey) {
            refreshShortcutParameters()
            defaults.set(digest, forKey: Self.publishedShortcutsKey)
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
            let state = SearchableConnection.digest(of: next, build: build)
            // A new process learns what the index holds from the state the last replace stored. A state that
            // cannot be read is treated as different, so the index is written rather than left as it is.
            if indexed == nil, (try? await searchIndex.storedState()) == state {
                indexed = next
                continue
            }
            do {
                try await searchIndex.replaceConnections(with: next, state: state)
                indexed = next
            } catch {
                indexed = nil
                Self.logger.error("Spotlight replace failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        replacing = nil
    }
}
