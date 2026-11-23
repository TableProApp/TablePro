//
//  DatabaseTypeChooserModel.swift
//  TablePro
//

import AppKit
import Combine
import Foundation

@MainActor
final class DatabaseTypeChooserModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet { settleHighlight() }
    }

    @Published var highlightedType: DatabaseType?

    private let allTypes: [DatabaseType]

    init(types: [DatabaseType]? = nil) {
        if let types {
            self.allTypes = types
        } else {
            self.allTypes = PluginManager.shared.allAvailableDatabaseTypes
        }
    }

    func preselect(_ type: DatabaseType?) {
        highlightedType = type
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var filteredTypes: [DatabaseType] {
        let query = query
        guard !query.isEmpty else { return allTypes }
        return allTypes.filter { Self.rank(of: $0, for: query) != nil }
    }

    // While searching, the best match leads: its section first, and within a section the closer names first.
    var groupedTypes: [(category: DatabaseCategory, types: [DatabaseType])] {
        let query = query
        let grouped = Dictionary(grouping: filteredTypes, by: { $0.category })
        guard !query.isEmpty else {
            return grouped
                .map { (category: $0.key, types: $0.value.sorted { $0.rawValue < $1.rawValue }) }
                .sorted { $0.category.sortOrder < $1.category.sortOrder }
        }
        func rank(_ type: DatabaseType) -> Int { Self.rank(of: type, for: query) ?? .max }
        return grouped
            .map { entry in
                (category: entry.key, types: entry.value.sorted { lhs, rhs in
                    rank(lhs) == rank(rhs) ? lhs.rawValue < rhs.rawValue : rank(lhs) < rank(rhs)
                })
            }
            .sorted { lhs, rhs in
                let left = lhs.types.first.map(rank) ?? .max
                let right = rhs.types.first.map(rank) ?? .max
                return left == right ? lhs.category.sortOrder < rhs.category.sortOrder : left < right
            }
    }

    // Arrowing follows the rows as drawn.
    var orderedTypes: [DatabaseType] {
        groupedTypes.flatMap(\.types)
    }

    // A name match, never a tagline or category hit among several: Return would commit a driver the user never
    // looked at. A sole result is unambiguous whatever matched.
    var bestMatch: DatabaseType? {
        let query = query
        guard !query.isEmpty else { return nil }
        let candidates = orderedTypes
        if let first = candidates.first, let rank = Self.rank(of: first, for: query), rank < Self.otherMatch {
            return first
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static let otherMatch = 3

    // 0 the exact name, 1 a name prefix, 2 inside the name, 3 the tagline or category; nil no match.
    private static func rank(of type: DatabaseType, for query: String) -> Int? {
        let name = type.rawValue.lowercased()
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        if let tagline = type.tagline, tagline.lowercased().contains(query) { return otherMatch }
        if type.category.displayName.lowercased().contains(query) { return otherMatch }
        return nil
    }

    func moveHighlight(by offset: Int) {
        let items = orderedTypes
        guard !items.isEmpty else { return }
        guard let current = highlightedType, let index = items.firstIndex(of: current) else {
            highlightedType = offset > 0 ? items.first : items.last
            return
        }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        highlightedType = items[target]
    }

    // Each query arms its best match, so typing on past a prefix PGlite matched lands on PostgreSQL. Without one the
    // highlight stays while it is still on screen, and a tagline-only query arms nothing.
    private func settleHighlight() {
        if let best = bestMatch {
            highlightedType = best
            return
        }
        if let current = highlightedType, orderedTypes.contains(current) { return }
        highlightedType = nil
    }
}

// The check Welcome runs after the chooser (WelcomeViewModel+ConnectionCreation), shared so a type change
// inside the editor asks the same question before it applies.
@MainActor
internal enum DatabaseTypeInstallCheck {
    internal enum Requirement: Equatable, Sendable {
        case ready
        case install
    }

    // A bundled driver that did not load is disabled or damaged: no download fixes it, the connect says which.
    nonisolated internal static func requirement(isInstalled: Bool, isDownloadable: Bool) -> Requirement {
        !isInstalled && isDownloadable ? .install : .ready
    }

    internal static func requirement(for type: DatabaseType) -> Requirement {
        requirement(
            isInstalled: PluginManager.shared.isDriverInstalled(for: type),
            isDownloadable: type.isDownloadablePlugin
        )
    }

    // True when the type can be used now: installed already, or the user agreed and the install finished.
    internal static func ensureInstalled(_ type: DatabaseType, window: NSWindow?) async -> Bool {
        if !PluginManager.shared.isDriverInstalled(for: type) {
            await PluginManager.shared.waitForInitialLoad()
        }
        guard requirement(for: type) == .install else { return true }

        let confirmed = await AlertHelper.confirm(
            title: String(localized: "Plugin Not Installed"),
            message: String(
                format: String(localized: "The %@ plugin is not installed. Would you like to install it?"),
                type.displayName
            ),
            confirmButton: String(localized: "Install"),
            window: window
        )
        guard confirmed else { return false }
        return await PluginInstallPrompt.run(pluginName: type.displayName, window: window) { onBegin in
            try await PluginManager.shared.installMissingPlugin(for: type, onBegin: onBegin)
        }
    }
}
