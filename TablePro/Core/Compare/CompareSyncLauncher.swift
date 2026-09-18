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

    /// A sheet on the window the user was working in, through the one presentation path every other
    /// alert in the app uses.
    ///
    /// `runModal()` here held the whole main thread application-modally. Under `UITestCase` the
    /// licence is always absent, because the suite launches into a throwaway container, so every UI
    /// test that reached a Compare & Sync menu item froze the app and took the unrelated cases after
    /// it in the same shard down with it, reporting as "not hittable" and "the sample database never
    /// finished opening".
    private static func presentUpgradeAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Compare & Sync requires a license")
        alert.informativeText = ProFeature.compareSync.featureDescription
        alert.addButton(withTitle: String(localized: "View License"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        AlertHelper.present(alert, in: NSApp.keyWindow) { response in
            guard response == .alertFirstButtonReturn else { return }
            WindowOpener.shared.openSettings(tab: .account)
        }
    }
}
