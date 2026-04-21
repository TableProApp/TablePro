//
//  MCPSettings.swift
//  TablePro
//
//  User-configurable MCP server preferences
//

import Foundation

struct MCPSettings: Codable, Equatable {
    var enabled: Bool
    var port: Int
    var defaultRowLimit: Int
    var maxRowLimit: Int
    var queryTimeoutSeconds: Int
    var logQueriesInHistory: Bool

    static let `default` = MCPSettings(
        enabled: false,
        port: 23508,
        defaultRowLimit: 500,
        maxRowLimit: 10_000,
        queryTimeoutSeconds: 30,
        logQueriesInHistory: true
    )

    init(
        enabled: Bool = false,
        port: Int = 23508,
        defaultRowLimit: Int = 500,
        maxRowLimit: Int = 10_000,
        queryTimeoutSeconds: Int = 30,
        logQueriesInHistory: Bool = true
    ) {
        self.enabled = enabled
        self.port = port
        self.defaultRowLimit = defaultRowLimit
        self.maxRowLimit = maxRowLimit
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.logQueriesInHistory = logQueriesInHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let rawPort = try container.decodeIfPresent(Int.self, forKey: .port) ?? 23508
        port = (1...65535).contains(rawPort) ? rawPort : 23508
        defaultRowLimit = try container.decodeIfPresent(Int.self, forKey: .defaultRowLimit) ?? 500
        maxRowLimit = try container.decodeIfPresent(Int.self, forKey: .maxRowLimit) ?? 10_000
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? 30
        logQueriesInHistory = try container.decodeIfPresent(Bool.self, forKey: .logQueriesInHistory) ?? true
    }
}
