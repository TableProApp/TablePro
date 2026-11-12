import Foundation

struct MCPSettings: Codable, Equatable {
    var enabled: Bool
    var port: Int
    var defaultRowLimit: Int
    var maxRowLimit: Int
    var queryTimeoutSeconds: Int
    var logQueriesInHistory: Bool
    var connectionApproval: MCPConnectionApproval
    var allowsHiddenConnectionListing: Bool

    // Linux takes the same range, so one client setup works against either app.
    static let portRange: ClosedRange<Int> = 1_024...65_535

    static let `default` = MCPSettings(
        enabled: false,
        port: 23_508,
        defaultRowLimit: 500,
        maxRowLimit: 10_000,
        queryTimeoutSeconds: 30,
        logQueriesInHistory: true,
        connectionApproval: .oncePerConnection,
        allowsHiddenConnectionListing: false
    )

    init(
        enabled: Bool = false,
        port: Int = 23_508,
        defaultRowLimit: Int = 500,
        maxRowLimit: Int = 10_000,
        queryTimeoutSeconds: Int = 30,
        logQueriesInHistory: Bool = true,
        connectionApproval: MCPConnectionApproval = .oncePerConnection,
        allowsHiddenConnectionListing: Bool = false
    ) {
        self.enabled = enabled
        self.port = port
        self.defaultRowLimit = defaultRowLimit
        self.maxRowLimit = maxRowLimit
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.logQueriesInHistory = logQueriesInHistory
        self.connectionApproval = connectionApproval
        self.allowsHiddenConnectionListing = allowsHiddenConnectionListing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        enabled = container.decodeSetting(.enabled, default: fallback.enabled)
        let rawPort = container.decodeSetting(.port, default: fallback.port)
        port = Self.portRange.contains(rawPort) ? rawPort : fallback.port
        defaultRowLimit = container.decodeSetting(.defaultRowLimit, default: fallback.defaultRowLimit)
        maxRowLimit = container.decodeSetting(.maxRowLimit, default: fallback.maxRowLimit)
        queryTimeoutSeconds = container.decodeSetting(.queryTimeoutSeconds, default: fallback.queryTimeoutSeconds)
        logQueriesInHistory = container.decodeSetting(.logQueriesInHistory, default: fallback.logQueriesInHistory)
        connectionApproval = container.decodeSetting(.connectionApproval, default: fallback.connectionApproval)
        allowsHiddenConnectionListing = container.decodeSetting(
            .allowsHiddenConnectionListing, default: fallback.allowsHiddenConnectionListing
        )

        maxRowLimit = validatedMaxRowLimit
        defaultRowLimit = validatedDefaultRowLimit
        queryTimeoutSeconds = validatedQueryTimeoutSeconds
    }

    var validatedPort: Int {
        port.clamped(to: Self.portRange)
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
