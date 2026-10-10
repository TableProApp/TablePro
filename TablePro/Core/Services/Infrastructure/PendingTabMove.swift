//
//  PendingTabMove.swift
//  TablePro
//

import Foundation
import os

/// A query tab on its way to another connection. The tab stays in its source until the target has a
/// coordinator that has settled its restore, so a connect that fails or is cancelled leaves it where it was.
@MainActor
internal struct PendingTabMove {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TabConnectionMove")

    /// The newest move asked for each tab. An older one still queued behind a slow connect must not
    /// take the tab away from wherever a later move put it.
    private static var latestMoveIds: [UUID: UUID] = [:]

    internal enum Refusal: String {
        case superseded
        case sourceGone
        case tabGone
        case notMovable
        case userReturned
        case fileAlreadyOpen
        case targetCannotSave
    }

    internal let tabId: UUID
    internal let moveId = UUID()
    private weak var source: MainContentCoordinator?
    /// Whether the source connection is on screen in the key window. A move that waited on a
    /// connect is refused when the user has gone back to the tab, rather than taken from under them.
    private let isSourceOnScreen: () -> Bool

    internal init(tabId: UUID, source: MainContentCoordinator, isSourceOnScreen: @escaping () -> Bool) {
        self.tabId = tabId
        self.source = source
        self.isSourceOnScreen = isSourceOnScreen
        Self.latestMoveIds[tabId] = moveId
    }

    internal var isSuperseded: Bool {
        Self.latestMoveIds[tabId] != moveId
    }

    internal func refusal(landingIn target: MainContentCoordinator, afterWaiting: Bool) -> Refusal? {
        guard !isSuperseded else { return .superseded }
        guard let source, !source.isTearingDown else { return .sourceGone }
        guard let tab = source.tabManager.tabs.first(where: { $0.id == tabId }) else { return .tabGone }
        guard source.canMoveTabToConnection(tabId) else { return .notMovable }
        if afterWaiting, source.tabManager.selectedTabId == tabId, isSourceOnScreen() {
            return .userReturned
        }
        if let url = tab.content.sourceFileURL, Self.holdsFile(url, target: target) {
            return .fileAlreadyOpen
        }
        /// The source drops the tab from disk as it lets go, so a target that cannot write it yet
        /// would hold the only copy in memory.
        guard target.persistence.hasObservedTabs else { return .targetCannotSave }
        return nil
    }

    /// `afterWaiting` is false only for a move that lands in the same call that asked for it.
    @discardableResult
    internal func land(in target: MainContentCoordinator, afterWaiting: Bool) -> Bool {
        defer { retire() }
        if let refusal = refusal(landingIn: target, afterWaiting: afterWaiting) {
            Self.logger.info(
                "[move] refused tabId=\(tabId, privacy: .public) target=\(target.connectionId, privacy: .public) reason=\(refusal.rawValue, privacy: .public)"
            )
            return false
        }
        guard let source, let moved = source.takeTabForMove(id: tabId) else { return false }
        target.adoptMovedTab(moved)
        /// The source has already dropped the tab from disk. The target has read its saved set by now,
        /// so writing it here is what keeps a quit in the next moment from losing the tab.
        target.persistence.saveAggregatedSync()
        Self.logger.info(
            "[move] landed tabId=\(tabId, privacy: .public) from=\(source.connectionId, privacy: .public) to=\(target.connectionId, privacy: .public)"
        )
        return true
    }

    internal func drop(reason: String) {
        Self.logger.info("[move] dropped tabId=\(tabId, privacy: .public) reason=\(reason, privacy: .public)")
        retire()
    }

    private func retire() {
        guard Self.latestMoveIds[tabId] == moveId else { return }
        Self.latestMoveIds.removeValue(forKey: tabId)
    }

    private static func holdsFile(_ url: URL, target: MainContentCoordinator) -> Bool {
        let tabs = target.tabManager.tabs + MainContentCoordinator.allTabs(for: target.connectionId)
        return tabs.contains { $0.content.sourceFileURL == url }
    }
}
