//
//  OperationNotificationPayload.swift
//  TablePro
//

import Foundation
import UserNotifications

// In userInfo, not targetContentIdentifier, which the system reads as a scene id an AppKit app has none of.
internal struct OperationNotificationPayload {
    private enum Key {
        static let windowId = "windowId"
        static let tabId = "tabId"
        static let connectionId = "connectionId"
        static let compareWindowId = "compareWindowId"
        static let failureReason = "failureReason"
        static let revealURL = "revealURL"
    }

    internal let windowId: UUID?
    internal let tabId: UUID?
    internal let connectionId: UUID?
    internal let compareWindowId: UUID?
    internal let failureReason: String?
    internal let revealURL: URL?

    internal init(plan: NotificationPlan) {
        switch plan.owner {
        case .tab(let windowId, let tabId):
            self.windowId = windowId
            self.tabId = tabId
            connectionId = UUID(uuidString: plan.threadIdentifier)
            compareWindowId = nil
        case .connection(let connectionId):
            windowId = nil
            tabId = nil
            self.connectionId = connectionId
            compareWindowId = nil
        case .compareWindow(let id):
            windowId = nil
            tabId = nil
            connectionId = UUID(uuidString: plan.threadIdentifier)
            compareWindowId = id
        }
        failureReason = plan.failureReason
        revealURL = plan.revealURL
    }

    internal init?(userInfo: [AnyHashable: Any]) {
        windowId = (userInfo[Key.windowId] as? String).flatMap(UUID.init(uuidString:))
        tabId = (userInfo[Key.tabId] as? String).flatMap(UUID.init(uuidString:))
        connectionId = (userInfo[Key.connectionId] as? String).flatMap(UUID.init(uuidString:))
        compareWindowId = (userInfo[Key.compareWindowId] as? String).flatMap(UUID.init(uuidString:))
        failureReason = userInfo[Key.failureReason] as? String
        revealURL = (userInfo[Key.revealURL] as? String).flatMap(URL.init(string:))
        guard tabId != nil || connectionId != nil || compareWindowId != nil || failureReason != nil || revealURL != nil else {
            return nil
        }
    }

    internal var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        info[Key.windowId] = windowId?.uuidString
        info[Key.tabId] = tabId?.uuidString
        info[Key.connectionId] = connectionId?.uuidString
        info[Key.compareWindowId] = compareWindowId?.uuidString
        info[Key.failureReason] = failureReason
        info[Key.revealURL] = revealURL?.absoluteString
        return info
    }
}
