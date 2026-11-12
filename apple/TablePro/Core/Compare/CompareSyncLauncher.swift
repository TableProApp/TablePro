//
//  CompareSyncLauncher.swift
//  TablePro
//
//  Single entry point for opening Compare & Sync, so the license gate is
//  enforced in one place no matter which menu or context menu was used.
//

import AppKit
import Foundation

@MainActor
internal enum CompareSyncLauncher {
    internal static func open(prefillSource connectionId: UUID? = nil) {
        guard FeatureAccess.shared.isAvailable(.compareSync) else {
            LicenseGateAlert.present(for: .compareSync, in: NSApp.keyWindow)
            return
        }
        WindowOpener.shared.openCompareSync(prefillSource: connectionId)
    }
}
