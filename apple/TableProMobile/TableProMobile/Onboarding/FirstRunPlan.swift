import Foundation

nonisolated enum FirstRunPage: Hashable, Sendable {
    case welcome
    case iCloud
}

nonisolated enum LaunchPresentation: Hashable, Sendable {
    case none
    case firstRun([FirstRunPage])
    case whatsNew(version: String)
}

nonisolated struct FirstRunPlan: Sendable {
    let hasSeenWelcome: Bool
    let syncChoice: Bool?
    let lastSeenVersion: String?
    let currentVersion: String
    let hasHighlightsForCurrentVersion: Bool

    var presentation: LaunchPresentation {
        let pages = firstRunPages
        if !pages.isEmpty {
            return .firstRun(pages)
        }
        guard isUpgrade, hasHighlightsForCurrentVersion else { return .none }
        return .whatsNew(version: currentVersion)
    }

    private var firstRunPages: [FirstRunPage] {
        guard !hasSeenWelcome else { return [] }
        return syncChoice == nil ? [.welcome, .iCloud] : [.welcome]
    }

    private var isUpgrade: Bool {
        guard let lastSeenVersion else { return false }
        return Self.isNewer(currentVersion, than: lastSeenVersion)
    }

    // The App Store takes only period-separated integers as a version, which a numeric comparison orders.
    static func isNewer(_ version: String, than seen: String) -> Bool {
        seen.compare(version, options: .numeric) == .orderedAscending
    }
}
