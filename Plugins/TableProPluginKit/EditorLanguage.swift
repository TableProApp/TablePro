//
//  EditorLanguage.swift
//  TableProPluginKit
//

public enum EditorLanguage: Sendable, Equatable {
    case sql
    case javascript
    case bash
    case custom(String)
}

extension EditorLanguage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "sql": self = .sql
        case "javascript": self = .javascript
        case "bash": self = .bash
        case "custom":
            let value = try container.decode(String.self, forKey: .value)
            self = .custom(value)
        default:
            self = .custom(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sql:
            try container.encode("sql", forKey: .type)
        case .javascript:
            try container.encode("javascript", forKey: .type)
        case .bash:
            try container.encode("bash", forKey: .type)
        case .custom(let value):
            try container.encode("custom", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
