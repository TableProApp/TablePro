//
//  ContextItem.swift
//  TablePro
//

import Foundation

enum ContextItem: Codable, Equatable, Sendable {
    case schema(connectionId: UUID)
    case table(connectionId: UUID, name: String)
    case currentQuery(text: String)
    case queryResult(summary: String)
    case savedQuery(id: UUID)
    case file(url: URL)

    private enum CodingKeys: String, CodingKey {
        case kind, connectionId, name, text, summary, id, url
    }

    private enum Kind: String, Codable {
        case schema, table, currentQuery, queryResult, savedQuery, file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .schema:
            let connectionId = try container.decode(UUID.self, forKey: .connectionId)
            self = .schema(connectionId: connectionId)
        case .table:
            let connectionId = try container.decode(UUID.self, forKey: .connectionId)
            let name = try container.decode(String.self, forKey: .name)
            self = .table(connectionId: connectionId, name: name)
        case .currentQuery:
            self = .currentQuery(text: try container.decode(String.self, forKey: .text))
        case .queryResult:
            self = .queryResult(summary: try container.decode(String.self, forKey: .summary))
        case .savedQuery:
            self = .savedQuery(id: try container.decode(UUID.self, forKey: .id))
        case .file:
            self = .file(url: try container.decode(URL.self, forKey: .url))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .schema(let connectionId):
            try container.encode(Kind.schema, forKey: .kind)
            try container.encode(connectionId, forKey: .connectionId)
        case .table(let connectionId, let name):
            try container.encode(Kind.table, forKey: .kind)
            try container.encode(connectionId, forKey: .connectionId)
            try container.encode(name, forKey: .name)
        case .currentQuery(let text):
            try container.encode(Kind.currentQuery, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .queryResult(let summary):
            try container.encode(Kind.queryResult, forKey: .kind)
            try container.encode(summary, forKey: .summary)
        case .savedQuery(let id):
            try container.encode(Kind.savedQuery, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .file(let url):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(url, forKey: .url)
        }
    }
}
