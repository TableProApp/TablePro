//
//  UpdaterSettingsWriting.swift
//  TablePro
//

import Foundation

/// The update preferences a view is allowed to change, so the settings pane can be tested
/// without a live Sparkle updater.
@MainActor
public protocol UpdaterSettingsWriting: AnyObject {
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get }
    var allowsAutomaticUpdates: Bool { get }
    var updateCheckInterval: TimeInterval { get }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool)
    func setAutomaticallyDownloadsUpdates(_ enabled: Bool)
    func setUpdateCheckInterval(_ interval: TimeInterval)
}
