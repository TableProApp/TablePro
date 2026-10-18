import Foundation

enum SparkleUpdatePreferences {
    static let userSettableKeys = [
        "SUEnableAutomaticChecks",
        "SUScheduledCheckInterval",
        "SUAutomaticallyUpdate",
    ]

    static func reset(in defaults: UserDefaults) {
        for key in userSettableKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
