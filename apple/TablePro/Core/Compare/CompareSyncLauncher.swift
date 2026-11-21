//
//  CompareSyncLauncher.swift
//  TablePro
//

import AppKit
import Foundation
import os

// Every way into Compare & Sync passes here, so the module switch and the license gate are checked in one place.
@MainActor
internal enum CompareSyncLauncher {
    internal enum Launch: Equatable {
        case moduleOff
        case needsLicense
        case open
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "CompareSync")

    // The license is not read while the module is off.
    internal static func launch(moduleEnabled: Bool, isLicensed: () -> Bool) -> Launch {
        guard moduleEnabled else { return .moduleOff }
        return isLicensed() ? .open : .needsLicense
    }

    internal static func open(prefillSource connectionId: UUID? = nil) {
        let decision = launch(moduleEnabled: AppModuleSettings.shared.isEnabled(.compareSync)) {
            FeatureAccess.shared.isAvailable(.compareSync)
        }
        switch decision {
        case .moduleOff:
            logger.notice("Compare & Sync was asked to open while its module is off")
        case .needsLicense:
            LicenseGateAlert.present(for: .compareSync, in: NSApp.keyWindow)
        case .open:
            CompareSyncWindowController.present(prefillSource: connectionId)
        }
    }
}
