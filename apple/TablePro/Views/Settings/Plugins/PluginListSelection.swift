//
//  PluginListSelection.swift
//  TablePro
//

import Foundation

// A rejected bundle can carry the id of a loaded plugin, so rejected rows are told apart by URL.
internal enum PluginListSelection: Hashable {
    case plugin(String)
    case rejected(URL)

    // A loaded plugin wins over a rejected copy of the same id. With no id, the first plugin that needs
    // an update is shown, since that is what a connection failure that names none is about.
    internal static func revealTarget(
        pluginId: String?,
        loadedIds: [String],
        rejected: [RejectedPlugin]
    ) -> PluginListSelection? {
        if let pluginId {
            if loadedIds.contains(pluginId) { return .plugin(pluginId) }
            if let match = rejected.first(where: { $0.bundleId == pluginId || $0.registryId == pluginId }) {
                return .rejected(match.url)
            }
            return nil
        }
        let first = rejected.first(where: \.isOutdated) ?? rejected.first
        return first.map { .rejected($0.url) }
    }
}

internal struct RejectedPluginStatus: Equatable {
    let caption: String
    let severity: NoticeSeverity

    internal init(action: RejectedPluginAction) {
        switch action {
        case .updateAvailable:
            caption = String(localized: "Update available")
            severity = .warning
        case .awaitingCompatibleBuild:
            caption = String(localized: "Waiting for a compatible build")
            severity = .warning
        case .requiresAppUpdate:
            caption = String(localized: "Needs a newer TablePro")
            severity = .warning
        case .notInRegistry:
            caption = String(localized: "Can't be loaded")
            severity = .error
        }
    }
}
