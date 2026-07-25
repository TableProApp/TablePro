//
//  PrismaSchemaExtractor.swift
//  TablePro
//

import Foundation

enum PrismaSchemaExtractor {
    static func extract(
        contents: String,
        relativePath: String,
        directoryURL: URL,
        projectRootURL: URL,
        environment: DotenvDocument?,
        fileManager: FileManager
    ) -> [ScannedConnectionCandidate] {
        guard let block = datasourceBlock(in: contents) else {
            return []
        }
        guard let provider = value(of: "provider", in: block),
              let type = providerType(provider) else {
            return []
        }
        guard let rawURL = resolvedURL(in: block, environment: environment) else {
            return []
        }
        if type == .sqlite || rawURL.lowercased().hasPrefix("file:") {
            return sqliteCandidate(
                rawURL: rawURL,
                relativePath: relativePath,
                directoryURL: directoryURL,
                projectRootURL: projectRootURL,
                fileManager: fileManager
            )
        }
        let candidate = ScannedConnectionURLBuilder.candidate(
            fromURL: rawURL,
            key: "datasource.url",
            relativePath: relativePath,
            kind: .prismaSchema,
            tier: .configFile
        )
        return candidate.map { [$0] } ?? []
    }

    static func datasourceBlock(in contents: String) -> String? {
        guard let start = contents.range(of: "datasource", options: .caseInsensitive) else {
            return nil
        }
        guard let open = contents.range(of: "{", range: start.upperBound..<contents.endIndex) else {
            return nil
        }
        guard let close = contents.range(of: "}", range: open.upperBound..<contents.endIndex) else {
            return nil
        }
        return String(contents[open.upperBound..<close.lowerBound])
    }

    static func value(of key: String, in block: String) -> String? {
        for rawLine in block.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key) else {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                continue
            }
            let remainder = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    private static func resolvedURL(in block: String, environment: DotenvDocument?) -> String? {
        guard let raw = value(of: "url", in: block) else {
            return nil
        }
        if let name = environmentVariableName(in: raw) {
            return environment?[name]
        }
        return unquoted(raw)
    }

    static func environmentVariableName(in value: String) -> String? {
        guard value.hasPrefix("env(") else {
            return nil
        }
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else {
            return nil
        }
        let inner = String(value[value.index(after: open)..<close])
        let name = unquoted(inner.trimmingCharacters(in: .whitespaces))
        return name.isEmpty ? nil : name
    }

    private static func sqliteCandidate(
        rawURL: String,
        relativePath: String,
        directoryURL: URL,
        projectRootURL: URL,
        fileManager: FileManager
    ) -> [ScannedConnectionCandidate] {
        var path = rawURL
        if let colon = path.firstIndex(of: ":"), path.lowercased().hasPrefix("file:") {
            path = String(path[path.index(after: colon)...])
        }
        if path.hasPrefix("//") {
            path = String(path.dropFirst(2))
        }
        guard !path.isEmpty else {
            return []
        }
        var fields = ScannedConnectionFields(type: .sqlite)
        fields.database = resolveSQLitePath(
            path,
            directoryURL: directoryURL,
            projectRootURL: projectRootURL,
            fileManager: fileManager
        )
        let candidate = ScannedConnectionCandidate(
            parsedURL: fields.toParsedConnectionURL(),
            sourceRelativePath: relativePath,
            sourceKey: "datasource.url",
            kind: .prismaSchema,
            tier: .configFile
        )
        return [candidate]
    }

    static func resolveSQLitePath(
        _ path: String,
        directoryURL: URL,
        projectRootURL: URL,
        fileManager: FileManager
    ) -> String {
        guard !path.hasPrefix("/") else {
            return path
        }
        let schemaRelative = directoryURL.appendingPathComponent(path).standardizedFileURL
        if fileManager.fileExists(atPath: schemaRelative.path) {
            return schemaRelative.path
        }
        let rootRelative = projectRootURL.appendingPathComponent(path).standardizedFileURL
        if fileManager.fileExists(atPath: rootRelative.path) {
            return rootRelative.path
        }
        return schemaRelative.path
    }

    private static func providerType(_ provider: String) -> DatabaseType? {
        switch unquoted(provider).lowercased() {
        case "postgresql", "postgres":
            return .postgresql
        case "mysql":
            return .mysql
        case "sqlite":
            return .sqlite
        case "sqlserver":
            return .mssql
        case "mongodb":
            return .mongodb
        case "cockroachdb":
            return .cockroachdb
        default:
            return nil
        }
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else {
            return value
        }
        guard first == last, first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
