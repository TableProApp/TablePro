//
//  NotificationSettings.swift
//  TablePro
//

import Foundation

/// Which finished operations are worth a notification, and how long is long enough to count.
///
/// Kinds are stored as the ones the user turned OFF rather than the ones left on, so a kind added
/// by a later release arrives enabled instead of silently missing from an older stored set. They
/// are stored as raw strings for the same reason in the other direction: a build that does not
/// know a kind must skip it, not fail to decode the whole settings record.
struct NotificationSettings: Codable, Equatable {
    static let minimumThresholdSeconds = 5
    static let maximumThresholdSeconds = 600
    static let defaultThresholdSeconds = 20

    var isEnabled: Bool
    var thresholdSeconds: Int
    var disabledKindIds: Set<String>

    static let `default` = NotificationSettings()

    var validatedThresholdSeconds: Int {
        min(max(thresholdSeconds, Self.minimumThresholdSeconds), Self.maximumThresholdSeconds)
    }

    func isEnabled(for kind: TrackedOperationKind) -> Bool {
        isEnabled && !disabledKindIds.contains(kind.rawValue)
    }

    mutating func setEnabled(_ enabled: Bool, for kind: TrackedOperationKind) {
        if enabled {
            disabledKindIds.remove(kind.rawValue)
        } else {
            disabledKindIds.insert(kind.rawValue)
        }
    }

    init(
        isEnabled: Bool = true,
        thresholdSeconds: Int = NotificationSettings.defaultThresholdSeconds,
        disabledKindIds: Set<String> = []
    ) {
        self.isEnabled = isEnabled
        self.thresholdSeconds = thresholdSeconds
        self.disabledKindIds = disabledKindIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        thresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .thresholdSeconds)
            ?? Self.defaultThresholdSeconds
        disabledKindIds = try container.decodeIfPresent(Set<String>.self, forKey: .disabledKindIds) ?? []
    }
}
