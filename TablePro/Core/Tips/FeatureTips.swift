//
//  FeatureTips.swift
//  TablePro
//

import SwiftUI
import TipKit

internal struct KeepTableOpenTip: Tip {
    static let tipId = "keep-table-open"
    static let previewTabReplaced = Tips.Event(id: "preview-tab-replaced")

    var id: String { Self.tipId }

    var title: Text {
        Text("Keep a Table Open")
    }

    var message: Text? {
        Text("A single click opens each table in the same preview tab. Double-click a table, or press Return, to keep it open.")
    }

    var image: Image? {
        Image(systemName: "square.on.square")
    }

    var rules: [Rule] {
        #Rule(Self.previewTabReplaced) { $0.donations.donatedWithin(.day).count >= 3 }
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(1)
    }
}

internal struct OpenQuicklyTip: Tip {
    static let tipId = "open-quickly"
    static let sidebarTableOpened = Tips.Event(id: "sidebar-table-opened")

    private let messageText: String

    init(shortcut: String? = nil) {
        messageText = FeatureTipCopy.openQuicklyMessage(shortcut: shortcut)
    }

    var id: String { Self.tipId }

    var title: Text {
        Text("Open Any Table by Name")
    }

    var message: Text? {
        Text(verbatim: messageText)
    }

    var rules: [Rule] {
        #Rule(Self.sidebarTableOpened) { $0.donations.donatedWithin(.week).count >= 8 }
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(2)
    }
}

internal struct FindPastQueriesTip: Tip {
    static let tipId = "find-past-queries"
    static let editorQueryRan = Tips.Event(id: "editor-query-ran")

    private let messageText: String

    init(shortcut: String? = nil) {
        messageText = FeatureTipCopy.findPastQueriesMessage(shortcut: shortcut)
    }

    var id: String { Self.tipId }

    var title: Text {
        Text("Find Past Queries")
    }

    var message: Text? {
        Text(verbatim: messageText)
    }

    var image: Image? {
        Image(systemName: "clock")
    }

    var rules: [Rule] {
        #Rule(Self.editorQueryRan) { $0.donations.count >= 10 }
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(1)
    }
}

internal enum FeatureTipCopy {
    static func openQuicklyMessage(shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else {
            return String(localized: "Choose File > Open Quickly… and type part of a name to open a table, database, or saved query.")
        }
        return String(
            format: String(localized: "Press %@ and type part of a name to open a table, database, or saved query."),
            shortcut
        )
    }

    static func findPastQueriesMessage(shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else {
            return String(localized: "Every query you run is saved. Choose View > Show Query History to search them and load one back into the editor.")
        }
        return String(
            format: String(localized: "Every query you run is saved. Press %@ to search them and load one back into the editor."),
            shortcut
        )
    }
}

internal enum FeatureTipCatalog {
    static var ids: [String] {
        [KeepTableOpenTip.tipId, OpenQuicklyTip.tipId, FindPastQueriesTip.tipId]
    }

    static func types(for ids: Set<String>) -> [any Tip.Type] {
        var types: [any Tip.Type] = []
        if ids.contains(KeepTableOpenTip.tipId) { types.append(KeepTableOpenTip.self) }
        if ids.contains(OpenQuicklyTip.tipId) { types.append(OpenQuicklyTip.self) }
        if ids.contains(FindPastQueriesTip.tipId) { types.append(FindPastQueriesTip.self) }
        return types
    }
}
