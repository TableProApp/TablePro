import Foundation

nonisolated enum FirstRunPage: Hashable, Sendable {
    case welcome
    case iCloud
    case usageData
}

nonisolated enum LaunchPresentation: Hashable, Sendable {
    case none
    case firstRun([FirstRunPage])
    case whatsNew(version: String)
}

nonisolated struct FirstRunPlan: Sendable {
    let hasSeenWelcome: Bool
    let syncChoice: Bool?
    let usageDataChoice: Bool?
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
        var pages: [FirstRunPage] = []
        if !hasSeenWelcome {
            pages.append(.welcome)
            if syncChoice == nil {
                pages.append(.iCloud)
            }
        }
        if usageDataChoice == nil {
            pages.append(.usageData)
        }
        return pages
    }

    private var isUpgrade: Bool {
        guard let lastSeenVersion else { return false }
        return lastSeenVersion != currentVersion
    }
}
