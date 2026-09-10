//
//  OperationNotificationPayload.swift
//  TablePro
//

import Foundation
import UserNotifications

/// What a delivered notification carries so its click knows where to go.
///
/// Routed through `userInfo` rather than `targetContentIdentifier`, which the system reads as a
/// scene identifier and which has no meaning for an AppKit app.
internal struct OperationNotificationPayload {
    private enum Key {
        static let windowId = "windowId"
        static let tabId = "tabId"
        static let connectionId = "connectionId"
        static let failureReason = "failureReason"
        static let revealURL = "revealURL"
    }

    internal let windowId: UUID?
    internal let tabId: UUID?
    internal let connectionId: UUID?
    internal let failureReason: String?
    internal let revealURL: URL?

    internal init(plan: NotificationPlan) {
        switch plan.owner {
        case .tab(let windowId, let tabId):
            self.windowId = windowId
            self.tabId = tabId
            connectionId = UUID(uuidString: plan.threadIdentifier)
        case .connection(let connectionId):
            windowId = nil
            tabId = nil
            self.connectionId = connectionId
        }
        failureReason = plan.failureReason
        revealURL = plan.revealURL
    }

    internal init?(userInfo: [AnyHashable: Any]) {
        windowId = (userInfo[Key.windowId] as? String).flatMap(UUID.init(uuidString:))
        tabId = (userInfo[Key.tabId] as? String).flatMap(UUID.init(uuidString:))
        connectionId = (userInfo[Key.connectionId] as? String).flatMap(UUID.init(uuidString:))
        failureReason = userInfo[Key.failureReason] as? String
        revealURL = (userInfo[Key.revealURL] as? String).flatMap(URL.init(string:))
        guard tabId != nil || connectionId != nil || failureReason != nil || revealURL != nil else {
            return nil
        }
    }

    internal var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        info[Key.windowId] = windowId?.uuidString
        info[Key.tabId] = tabId?.uuidString
        info[Key.connectionId] = connectionId?.uuidString
        info[Key.failureReason] = failureReason
        info[Key.revealURL] = revealURL?.absoluteString
        return info
    }
}
