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
}
