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
        guard LicenseManager.shared.isFeatureAvailable(.compareSync) else {
            presentUpgradeAlert()
            return
        }
        WindowOpener.shared.openCompareSync(prefillSource: connectionId)
    }

    private static func presentUpgradeAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Compare & Sync requires a license")
        alert.informativeText = ProFeature.compareSync.featureDescription
        alert.addButton(withTitle: String(localized: "View License"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WindowOpener.shared.openSettings(tab: .account)
    }
}
