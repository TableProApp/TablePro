//
//  CopilotSettings.swift
//  TablePro
//

import Foundation

struct CopilotSettings: Codable, Equatable {
    var enabled: Bool
    var telemetryEnabled: Bool

    static let `default` = CopilotSettings(
        enabled: false,
        telemetryEnabled: true
    )

    init(
        enabled: Bool = false,
        telemetryEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.telemetryEnabled = telemetryEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? true
    }
}
