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

    var filteredTypes: [DatabaseType] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allTypes }
        let needle = trimmed.lowercased()
        return allTypes.filter { type in
            if type.rawValue.lowercased().contains(needle) { return true }
            if let tagline = type.tagline, tagline.lowercased().contains(needle) { return true }
            if type.category.displayName.lowercased().contains(needle) { return true }
            return false
        }
    }

    var groupedTypes: [(category: DatabaseCategory, types: [DatabaseType])] {
        let grouped = Dictionary(grouping: filteredTypes, by: { $0.category })
        return grouped
            .map { (category: $0.key, types: $0.value.sorted { $0.rawValue < $1.rawValue }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    // Arrowing follows the rows as drawn: category order, then alphabetical.
    var orderedTypes: [DatabaseType] {
        groupedTypes.flatMap(\.types)
    }

    // Ranked, not the first row: the filter matches taglines too, so "PostgreSQL" puts CockroachDB on top
    // and Return would commit a driver the user never looked at.
    var bestMatch: DatabaseType? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidates = orderedTypes
        if let exact = candidates.first(where: { $0.rawValue.lowercased() == trimmed }) {
            return exact
        }
        if let prefixed = candidates.first(where: { $0.rawValue.lowercased().hasPrefix(trimmed) }) {
            return prefixed
        }
        if let named = candidates.first(where: { $0.rawValue.lowercased().contains(trimmed) }) {
            return named
        }
        return candidates.count == 1 ? candidates.first : nil
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

    // Never falls back to the first row: a tagline-only query leaves nothing armed and Continue dimmed.
    private func settleHighlight() {
        if let current = highlightedType, orderedTypes.contains(current) { return }
        highlightedType = bestMatch
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
