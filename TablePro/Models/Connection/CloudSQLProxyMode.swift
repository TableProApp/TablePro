//
//  CloudSQLProxyMode.swift
//  TablePro
//

import Foundation

enum CloudSQLProxyMode: Hashable, Sendable {
    case disabled
    case inline(CloudSQLProxyConfiguration)
}

extension CloudSQLProxyMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case config
    }

    private enum Mode: String, Codable {
        case disabled
        case inline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .disabled:
            self = .disabled
        case .inline:
            let config = try container.decode(CloudSQLProxyConfiguration.self, forKey: .config)
            self = .inline(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled:
            try container.encode(Mode.disabled, forKey: .mode)
        case .inline(let config):
            try container.encode(Mode.inline, forKey: .mode)
            try container.encode(config, forKey: .config)
        }
    }
}
