//
//  WindowLayoutMigration.swift
//  TablePro
//
//  One-time migration of window-layout UserDefaults from the old global keys
//  (shared across every connection window) to the per-connection keys used by
//  the one-window-per-connection model.
//

import AppKit
import os

@MainActor
internal enum WindowLayoutMigration {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowLayoutMigration")
    private static let migrationCompleteKey = "com.TablePro.windowLayoutMigrationComplete"

    private static let legacySplitAutosaveName = "com.TablePro.mainSplit"
    private static let legacyInspectorPresentedKey = "com.TablePro.rightPanel.isPresented"

    private static func splitFramesKey(_ autosaveName: String) -> String {
        "NSSplitView Subview Frames \(autosaveName)"
    }

    /// Seed each saved connection's per-connection layout keys from the old
    /// global values, once. Runs at launch before any window opens.
    internal static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationCompleteKey) else { return }

        let legacySplitFrames = defaults.array(forKey: splitFramesKey(legacySplitAutosaveName))
        let hasLegacyInspector = defaults.object(forKey: legacyInspectorPresentedKey) != nil
        let legacyInspectorPresented = defaults.bool(forKey: legacyInspectorPresentedKey)

        if legacySplitFrames == nil, !hasLegacyInspector {
            defaults.set(true, forKey: migrationCompleteKey)
            logger.trace("No legacy window-layout defaults found, migration skipped")
            return
        }

        let connections = ConnectionStorage.shared.loadConnections()
        for connection in connections {
            let perConnectionSplitKey = splitFramesKey("com.TablePro.mainSplit.\(connection.id.uuidString)")
            if let legacySplitFrames, defaults.object(forKey: perConnectionSplitKey) == nil {
                defaults.set(legacySplitFrames, forKey: perConnectionSplitKey)
            }

            let perConnectionInspectorKey = "com.TablePro.rightPanel.isPresented.\(connection.id.uuidString)"
            if hasLegacyInspector, defaults.object(forKey: perConnectionInspectorKey) == nil {
                defaults.set(legacyInspectorPresented, forKey: perConnectionInspectorKey)
            }
        }

        defaults.removeObject(forKey: splitFramesKey(legacySplitAutosaveName))
        defaults.removeObject(forKey: legacyInspectorPresentedKey)
        defaults.set(true, forKey: migrationCompleteKey)
        logger.trace("Window-layout migration complete for \(connections.count) connections")
    }
}
