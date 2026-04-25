import Foundation

struct MCPSettings: Codable, Equatable {
    var enabled: Bool
    var port: Int
    var defaultRowLimit: Int
    var maxRowLimit: Int
    var queryTimeoutSeconds: Int
    var logQueriesInHistory: Bool
    var requireAuthentication: Bool
    var allowRemoteConnections: Bool

    static let `default` = MCPSettings(
        enabled: false,
        port: 23_508,
        defaultRowLimit: 500,
        maxRowLimit: 10_000,
        queryTimeoutSeconds: 30,
        logQueriesInHistory: true,
        requireAuthentication: false,
        allowRemoteConnections: false
    )

    init(
        enabled: Bool = false,
        port: Int = 23_508,
        defaultRowLimit: Int = 500,
        maxRowLimit: Int = 10_000,
        queryTimeoutSeconds: Int = 30,
        logQueriesInHistory: Bool = true,
        requireAuthentication: Bool = false,
        allowRemoteConnections: Bool = false
    ) {
        self.enabled = enabled
        self.port = port
        self.defaultRowLimit = defaultRowLimit
        self.maxRowLimit = maxRowLimit
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.logQueriesInHistory = logQueriesInHistory
        self.requireAuthentication = requireAuthentication
        self.allowRemoteConnections = allowRemoteConnections
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
        requireAuthentication = try container.decodeIfPresent(Bool.self, forKey: .requireAuthentication) ?? false
        allowRemoteConnections = try container.decodeIfPresent(Bool.self, forKey: .allowRemoteConnections) ?? false
    }
}
