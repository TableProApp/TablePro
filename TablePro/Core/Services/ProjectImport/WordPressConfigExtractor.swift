//
//  WordPressConfigExtractor.swift
//  TablePro
//

import Foundation

enum WordPressConfigExtractor {
    private static let definePattern = #"define\(\s*['"]([A-Za-z_]+)['"]\s*,\s*['"]([^'"]*)['"]\s*\)"#

    static func extract(contents: String, relativePath: String) -> [ScannedConnectionCandidate] {
        let constants = parseConstants(contents)
        guard let database = constants["DB_NAME"] else {
            return []
        }
        var fields = ScannedConnectionFields(type: .mysql)
        fields.database = database
        fields.username = constants["DB_USER"] ?? ""
        fields.password = constants["DB_PASSWORD"] ?? ""
        var warnings: [String] = []
        let address = splitHost(constants["DB_HOST"] ?? "localhost")
        fields.host = address.host
        fields.port = address.port ?? 3_306
        if address.isSocket {
            warnings.append(String(localized: "Host looks like a socket path"))
        }
        let candidate = ScannedConnectionCandidate(
            parsedURL: fields.toParsedConnectionURL(),
            sourceRelativePath: relativePath,
            sourceKey: "DB_NAME",
            kind: .wordPressConfig,
            tier: .configFile,
            warnings: warnings
        )
        return [candidate]
    }

    static func parseConstants(_ contents: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: definePattern) else {
            return [:]
        }
        var constants: [String: String] = [:]
        var inBlockComment = false
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if line.contains("*/") {
                    inBlockComment = false
                }
                continue
            }
            if line.hasPrefix("/*") {
                inBlockComment = !line.contains("*/")
                continue
            }
            if line.hasPrefix("//") || line.hasPrefix("#") || line.hasPrefix("*") {
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            constants[String(line[keyRange])] = String(line[valueRange])
        }
        return constants
    }

    static func splitHost(_ value: String) -> (host: String, port: Int?, isSocket: Bool) {
        guard let colon = value.firstIndex(of: ":") else {
            return (value, nil, false)
        }
        let head = String(value[value.startIndex..<colon])
        let tail = String(value[value.index(after: colon)...])
        if let port = Int(tail) {
            return (head, port, false)
        }
        return (value, nil, tail.hasPrefix("/"))
    }
}
