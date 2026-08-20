import Foundation

struct MCPSettings: Codable, Equatable {
    var enabled: Bool
    var port: Int
    var defaultRowLimit: Int
    var maxRowLimit: Int
    var queryTimeoutSeconds: Int
    var logQueriesInHistory: Bool
    var requireAuthentication: Bool

    static let `default` = MCPSettings(
        enabled: false,
        port: 23_508,
        defaultRowLimit: 500,
        maxRowLimit: 10_000,
        queryTimeoutSeconds: 30,
        logQueriesInHistory: true,
        requireAuthentication: true
    )

    init(
        enabled: Bool = false,
        port: Int = 23_508,
        defaultRowLimit: Int = 500,
        maxRowLimit: Int = 10_000,
        queryTimeoutSeconds: Int = 30,
        logQueriesInHistory: Bool = true,
        requireAuthentication: Bool = true
    ) {
        self.enabled = enabled
        self.port = port
        self.defaultRowLimit = defaultRowLimit
        self.maxRowLimit = maxRowLimit
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.logQueriesInHistory = logQueriesInHistory
        self.requireAuthentication = requireAuthentication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let rawPort = try container.decodeIfPresent(Int.self, forKey: .port) ?? 23_508
        port = (1...65_535).contains(rawPort) ? rawPort : 23_508
        defaultRowLimit = try container.decodeIfPresent(Int.self, forKey: .defaultRowLimit) ?? 500
        maxRowLimit = try container.decodeIfPresent(Int.self, forKey: .maxRowLimit) ?? 10_000
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? 30
        logQueriesInHistory = try container.decodeIfPresent(Bool.self, forKey: .logQueriesInHistory) ?? true
        requireAuthentication = try container.decodeIfPresent(Bool.self, forKey: .requireAuthentication) ?? true

        maxRowLimit = validatedMaxRowLimit
        defaultRowLimit = validatedDefaultRowLimit
        queryTimeoutSeconds = validatedQueryTimeoutSeconds
    }

    var validatedMaxRowLimit: Int {
        maxRowLimit.clamped(to: SettingsValidationRules.mcpRowLimitRange)
    }

    var validatedDefaultRowLimit: Int {
        defaultRowLimit.clamped(to: SettingsValidationRules.mcpRowLimitRange)
    }

    var validatedQueryTimeoutSeconds: Int {
        queryTimeoutSeconds.clamped(to: SettingsValidationRules.mcpQueryTimeoutRange)
    }

    var effectiveDefaultRowLimit: Int {
        min(validatedDefaultRowLimit, validatedMaxRowLimit)
    }

    var requestableRowLimitRange: ClosedRange<Int> {
        SettingsValidationRules.mcpRowLimitRange.lowerBound...validatedMaxRowLimit
    }
}
