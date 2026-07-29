//
//  SOCKSProxyConfiguration.swift
//  TablePro
//

import Foundation

struct SOCKSProxyConfiguration: Codable, Hashable, Sendable {
    var host: String = ""
    var port: Int = 1_080
    var username: String = ""

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65_535).contains(port)
    }
}

extension SOCKSProxyConfiguration {
    private enum CodingKeys: String, CodingKey {
        case host, port, username
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 1_080
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    }
}
