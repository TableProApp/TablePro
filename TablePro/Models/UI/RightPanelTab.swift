//
//  RightPanelTab.swift
//  TablePro
//
//  Tab options for the unified right panel.
//

import Foundation

enum RightPanelTab: String, CaseIterable, Hashable {
    case details = "Details"
    case json    = "JSON"
    case aiChat  = "AI Chat"

    var localizedTitle: String {
        switch self {
        case .details: String(localized: "Details")
        case .json:    String(localized: "JSON")
        case .aiChat:  String(localized: "AI Chat")
        }
    }

    var systemImage: String {
        switch self {
        case .details: "info.circle"
        case .json:    "curlybraces"
        case .aiChat:  "sparkles"
        }
    }

    /// AI Chat is the only tab a setting can take away.
    static func available(isAIEnabled: Bool) -> [RightPanelTab] {
        allCases.filter { $0 != .aiChat || isAIEnabled }
    }

    /// The tab to show for a stored one, which can name a tab the settings no longer offer.
    ///
    /// The active tab is persisted per connection and restored without asking whether the tab
    /// still exists, so a connection last left on AI Chat comes back to it even with the assistant
    /// turned off since. Resolving on every read rather than only when the setting changes is what
    /// covers the restore, which no change notification ever reaches.
    static func resolved(_ tab: RightPanelTab, isAIEnabled: Bool) -> RightPanelTab {
        available(isAIEnabled: isAIEnabled).contains(tab) ? tab : .details
    }
}
