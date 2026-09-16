//
//  AccessibilityAnnouncement.swift
//  TablePro
//

import AppKit
import SwiftUI

/// `AccessibilityNotification.Announcement` is macOS 14. The fallback posts the same
/// `announcementRequested` notification AppKit has taken since 10.7, so VoiceOver hears
/// the identical string either way.
internal enum AccessibilityAnnouncement {
    internal static func post(_ message: String) {
        if #available(macOS 14.0, *) {
            AccessibilityNotification.Announcement(message).post()
            return
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
