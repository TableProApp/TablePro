//
//  ElasticsearchConsoleParser.swift
//  ElasticsearchDriverPlugin
//
//  Parses Kibana Dev Tools console input into a REST request.
//

import Foundation

struct ElasticsearchConsoleRequest: Equatable {
    let method: String
    let path: String
    let body: String?
}

enum ElasticsearchConsoleParser {
    static let supportedMethods: Set<String> = ["GET", "POST", "PUT", "DELETE", "HEAD"]

    static func parse(_ input: String) -> ElasticsearchConsoleRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var lines = trimmed.components(separatedBy: "\n")
        let header = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let methodPart = parts.first else { return nil }

        let method = String(methodPart).uppercased()
        guard supportedMethods.contains(method) else { return nil }

        let path = parts.count == 2 ? normalizePath(String(parts[1]).trimmingCharacters(in: .whitespaces)) : "/"

        let bodyText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ElasticsearchConsoleRequest(method: method, path: path, body: bodyText.isEmpty ? nil : bodyText)
    }

    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.hasPrefix("/") ? path : "/" + path
    }

    static func looksLikeConsoleInput(_ input: String) -> Bool {
        parse(input) != nil
    }
}
