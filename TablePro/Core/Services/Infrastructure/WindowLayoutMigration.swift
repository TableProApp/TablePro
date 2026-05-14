//
//  WindowLayoutMigration.swift
//  TablePro
//
//  One-time migration of window-layout UserDefaults from the old global keys
//  (shared across every connection window) to the per-connection keys used by
//  the one-window-per-connection model.
//

import Foundation
import os

@MainActor
internal enum WindowLayoutMigration {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowLayoutMigration")
    static let migrationCompleteKey = "com.TablePro.windowLayoutMigrationComplete"

    private static let legacySplitAutosaveName = "com.TablePro.mainSplit"
    private static let legacyInspectorPresentedKey = "com.TablePro.rightPanel.isPresented"

    static func splitFramesKey(_ autosaveName: String) -> String {
        "NSSplitView Subview Frames \(autosaveName)"
    }

    static func perConnectionSplitFramesKey(_ connectionId: UUID) -> String {
        splitFramesKey("com.TablePro.mainSplit.\(connectionId.uuidString)")
    }

    static func perConnectionInspectorKey(_ connectionId: UUID) -> String {
        "com.TablePro.rightPanel.isPresented.\(connectionId.uuidString)"
    }

    /// Seed each saved connection's per-connection layout keys from the old
    /// global values, once. Runs at launch before any window opens.
    static func runIfNeeded() {
        let connectionIds = ConnectionStorage.shared.loadConnections().map(\.id)
        migrate(defaults: .standard, connectionIds: connectionIds)
    }

    static func migrate(defaults: UserDefaults, connectionIds: [UUID]) {
        guard !defaults.bool(forKey: migrationCompleteKey) else { return }

        let legacySplitFrames = defaults.array(forKey: splitFramesKey(legacySplitAutosaveName))
        let hasLegacyInspector = defaults.object(forKey: legacyInspectorPresentedKey) != nil
        let legacyInspectorPresented = defaults.bool(forKey: legacyInspectorPresentedKey)

        if legacySplitFrames == nil, !hasLegacyInspector {
            defaults.set(true, forKey: migrationCompleteKey)
            logger.trace("No legacy window-layout defaults found, migration skipped")
            return
        }

        for connectionId in connectionIds {
            let perConnectionSplitKey = perConnectionSplitFramesKey(connectionId)
            if let legacySplitFrames, defaults.object(forKey: perConnectionSplitKey) == nil {
                defaults.set(legacySplitFrames, forKey: perConnectionSplitKey)
            }

            let inspectorKey = perConnectionInspectorKey(connectionId)
            if hasLegacyInspector, defaults.object(forKey: inspectorKey) == nil {
                defaults.set(legacyInspectorPresented, forKey: inspectorKey)
            }
        }

        defaults.removeObject(forKey: splitFramesKey(legacySplitAutosaveName))
        defaults.removeObject(forKey: legacyInspectorPresentedKey)
        defaults.set(true, forKey: migrationCompleteKey)
        logger.trace("Window-layout migration complete for \(connectionIds.count) connections")
    }
}
