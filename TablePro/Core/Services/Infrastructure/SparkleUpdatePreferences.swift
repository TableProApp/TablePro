//
//  SparkleUpdatePreferences.swift
//  TablePro
//

import Foundation

/// The Sparkle preference keys the app depends on, and the rule that every one of them carries a
/// default the app ships rather than a default Sparkle infers.
///
/// Sparkle resolves each key as user defaults first and the bundle's Info.plist second
/// (`SUHost.boolNumberForKey:`). A key declared in neither resolves to `NO`, and the three update
/// settings are chained: with `SUEnableAutomaticChecks` absent, `allowsAutomaticUpdates` is false,
/// and `SPUUpdaterSettings.setAutomaticallyDownloadsUpdates` then returns without writing anything.
/// So a `SUAutomaticallyUpdate` of `true` read as `false` at runtime, and the second toggle in the
/// settings pane was inert rather than merely dimmed.
///
/// `SparkleUpdatePreferencesTests` reads the running bundle and fails when a key here has no
/// declared default, which is the check that absence defeated.
enum SparkleUpdatePreferences {
    /// Sparkle writes these into the main bundle's standard domain through `SUHost` when the user
    /// changes a control. Removing them hands governance back to Info.plist, which is what
    /// resetting settings has to mean.
    static let userSettableKeys = [
        "SUEnableAutomaticChecks",
        "SUScheduledCheckInterval",
        "SUAutomaticallyUpdate",
    ]

    /// `SUScheduledImpatientCheckInterval` is deliberately absent: Sparkle's own default is the
    /// value we want, and a redeclared default is one more pair of numbers that can drift apart.
    static let requiredInfoPlistKeys = [
        "SUFeedURL",
        "SUPublicEDKey",
        "SUEnableAutomaticChecks",
        "SUScheduledCheckInterval",
        "SUAutomaticallyUpdate",
    ]

    static func reset(in defaults: UserDefaults) {
        for key in userSettableKeys {
            defaults.removeObject(forKey: key)
        }
    }

    static func keysMissingDefaults(in bundle: Bundle) -> [String] {
        requiredInfoPlistKeys.filter { bundle.object(forInfoDictionaryKey: $0) == nil }
    }
}
