//
//  RestorationGroupRegistry.swift
//  TablePro
//

import Foundation

enum RestoreLoadTiming {
    case immediate
    case deferred
}

@MainActor
enum RestorationGroupRegistry {
    struct WindowGroup {
        let tabs: [QueryTab]
        let selectedTabId: UUID?
        /// The container this group was browsing. It travels here rather than only on the payload
        /// because the payload's database and schema also name the lead tab for the window title,
        /// and a window can be browsing one container while its front tab reads another.
        var browseState = WindowBrowseState()
        var loadTiming: RestoreLoadTiming = .immediate
    }

    private static var groups: [UUID: WindowGroup] = [:]
    private static let entryLifetime: Duration = .seconds(10)

    static func register(_ group: WindowGroup, for payloadId: UUID) {
        groups[payloadId] = group
        Task { @MainActor in
            try? await Task.sleep(for: entryLifetime)
            groups.removeValue(forKey: payloadId)
        }
    }

    static func consume(for payloadId: UUID?) -> WindowGroup? {
        guard let payloadId else { return nil }
        return groups.removeValue(forKey: payloadId)
    }
}
