//
//  SplitViewAutosaveName.swift
//  TablePro
//

import Foundation
import TableProUtilities

internal enum SplitViewAutosaveName {
    /// Never version this: `NSSplitView` clamps a restored frame to the current minimums, and a new key discards every saved width.
    internal static let base = "com.TablePro.mainSplit"

    /// One width for the connections strip in every window, as the main split keeps one sidebar width.
    internal static let workspaceRail = "com.TablePro.workspaceRail"

    internal static let historyDrawerPrefix = "HistoryDrawer-"

    /// Per connection, not per tab: the query tab branch has no `.id(tab.id)`, so its split view keeps the name it was born with.
    internal static let querySplitPrefix = "QuerySplit-"

    internal static func historyDrawer(connectionId: UUID) -> String {
        "\(historyDrawerPrefix)\(connectionId.uuidString)"
    }

    internal static func querySplit(connectionId: UUID) -> String {
        "\(querySplitPrefix)\(connectionId.uuidString)"
    }

    /// AppKit's records for a connection's history drawer and query split, which it never removes
    /// itself. None exist in the unit test host or the storage sandbox, where `current` gives no name.
    @MainActor
    internal static func removeRecords(connectionId: UUID) {
        guard current(base) != nil else { return }
        removeRecords(connectionId: connectionId, defaults: .standard)
    }

    internal static func removeRecords(connectionId: UUID, defaults: UserDefaults) {
        for name in [historyDrawer(connectionId: connectionId), querySplit(connectionId: connectionId)] {
            defaults.removeObject(forKey: SplitViewAutosaveKey.key(forAutosaveName: name))
        }
    }

    /// Nil in the unit test host, the storage sandbox and a device profile, because AppKit files the record in the real
    /// standard domain.
    @MainActor
    internal static func current(_ name: String) -> String? {
        let environment = AppStorageEnvironment.shared
        return autosaveName(name, isUnitTestHost: environment.isUnitTestHost, isIsolated: !environment.isProductionStore)
    }

    internal static func autosaveName(_ name: String, isUnitTestHost: Bool, isIsolated: Bool) -> String? {
        isUnitTestHost || isIsolated ? nil : name
    }
}
