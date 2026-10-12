//
//  NotificationSettings.swift
//  TablePro
//

import Foundation

/// Whether a finished operation is worth a notification, and how long is long enough to count.
struct NotificationSettings: Codable, Equatable {
    static let minimumThresholdSeconds = 5
    static let maximumThresholdSeconds = 600
    static let defaultThresholdSeconds = 20

    var isEnabled: Bool
    var thresholdSeconds: Int

    static let `default` = NotificationSettings()

    var validatedThresholdSeconds: Int {
        min(max(thresholdSeconds, Self.minimumThresholdSeconds), Self.maximumThresholdSeconds)
    }

    init(
        isEnabled: Bool = true,
        thresholdSeconds: Int = NotificationSettings.defaultThresholdSeconds
    ) {
        self.isEnabled = isEnabled
        self.thresholdSeconds = thresholdSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        thresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .thresholdSeconds)
            ?? Self.defaultThresholdSeconds
    }
}
