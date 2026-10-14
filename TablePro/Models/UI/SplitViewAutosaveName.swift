//
//  SplitViewAutosaveName.swift
//  TablePro
//

import Foundation

internal enum SplitViewAutosaveName {
    /// Never version this: `NSSplitView` clamps a restored frame to the current minimums, and a new key discards every saved width.
    internal static let base = "com.TablePro.mainSplit"

    internal static let historyDrawerPrefix = "HistoryDrawer-"

    /// Per connection, not per tab: the query tab branch has no `.id(tab.id)`, so its split view keeps the name it was born with.
    internal static let querySplitPrefix = "QuerySplit-"

    internal static func historyDrawer(connectionId: UUID) -> String {
        "\(historyDrawerPrefix)\(connectionId.uuidString)"
    }

    internal static func querySplit(connectionId: UUID) -> String {
        "\(querySplitPrefix)\(connectionId.uuidString)"
    }

    /// Nil in the unit test host and the storage sandbox, because AppKit files the record in the real standard domain.
    @MainActor
    internal static func current(_ name: String) -> String? {
        let environment = AppStorageEnvironment.shared
        return autosaveName(name, isUnitTestHost: environment.isUnitTestHost, isIsolated: environment.isIsolated)
    }

    internal static func autosaveName(_ name: String, isUnitTestHost: Bool, isIsolated: Bool) -> String? {
        isUnitTestHost || isIsolated ? nil : name
    }
}
