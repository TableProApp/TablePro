import Foundation

// The threshold also decides the tab's unseen mark, with the switch on or off.
struct NotificationSettings: Codable, Equatable {
    static let minimumThresholdSeconds = 5
    static let maximumThresholdSeconds = 600
    static let defaultThresholdSeconds = 20
    static let thresholdChoices = [5, 10, 20, 30, 60, 120, 300, 600]

    var isEnabled: Bool
    var thresholdSeconds: Int

    static let `default` = NotificationSettings()

    var validatedThresholdSeconds: Int {
        min(max(thresholdSeconds, Self.minimumThresholdSeconds), Self.maximumThresholdSeconds)
    }

    var thresholdOptions: [Int] {
        let current = validatedThresholdSeconds
        guard !Self.thresholdChoices.contains(current) else { return Self.thresholdChoices }
        return (Self.thresholdChoices + [current]).sorted()
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
        let fallback = Self.default
        isEnabled = container.decodeSetting(.isEnabled, default: fallback.isEnabled)
        thresholdSeconds = container.decodeSetting(.thresholdSeconds, default: fallback.thresholdSeconds)
    }
}
