//
//  TypesenseConsoleParser.swift
//  TypesenseDriverPlugin
//
//  Parses console input into a Typesense REST request.
//

import Foundation

struct TypesenseConsoleRequest: Equatable {
    let method: String
    let path: String
    let body: String?
}

enum TypesenseConsoleParser {
    static let supportedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    static func parse(_ input: String) -> TypesenseConsoleRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var lines = trimmed.components(separatedBy: "\n")
        let header = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let methodPart = parts.first else { return nil }

        let method = String(methodPart).uppercased()
        guard supportedMethods.contains(method) else { return nil }

        let path = parts.count == 2 ? normalizePath(String(parts[1]).trimmingCharacters(in: .whitespaces)) : "/"
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return TypesenseConsoleRequest(method: method, path: path, body: body.isEmpty ? nil : body)
    }

    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.hasPrefix("/") ? path : "/" + path
    }

    static func looksLikeConsoleInput(_ input: String) -> Bool {
        parse(input) != nil
    }
}
