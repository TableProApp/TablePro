//
//  RailsDatabaseYamlExtractor.swift
//  TablePro
//

import Foundation

enum RailsDatabaseYamlExtractor {
    private static let preferredEnvironments = ["development", "production", "staging", "test"]

    static func extract(
        contents: String,
        relativePath: String,
        projectRootURL: URL,
        environment: DotenvDocument?
    ) -> [ScannedConnectionCandidate] {
        guard let root = YamlMappingSupport.loadMapping(contents) else {
            return []
        }
        guard let selected = selectEnvironment(root) else {
            return []
        }
        guard let adapter = YamlMappingSupport.string(selected.mapping["adapter"]),
              let type = adapterType(adapter) else {
            return []
        }
        var warnings: [String] = []
        var fields = ScannedConnectionFields(type: type)
        let resolver = ErbValueResolver(environment: environment)
        fields.database = resolver.resolve(
            YamlMappingSupport.string(selected.mapping["database"]),
            warnings: &warnings
        ) ?? ""
        guard type != .sqlite else {
            fields.database = absoluteSQLitePath(fields.database, projectRootURL: projectRootURL)
            return [candidate(fields: fields, relativePath: relativePath, key: selected.key, warnings: warnings)]
        }
        fields.host = resolver.resolve(
            YamlMappingSupport.string(selected.mapping["host"]),
            warnings: &warnings
        ) ?? "127.0.0.1"
        fields.username = resolver.resolve(
            YamlMappingSupport.string(selected.mapping["username"]),
            warnings: &warnings
        ) ?? ""
        fields.password = resolver.resolve(
            YamlMappingSupport.string(selected.mapping["password"]),
            warnings: &warnings
        ) ?? ""
        let port = resolver.resolve(YamlMappingSupport.string(selected.mapping["port"]), warnings: &warnings)
        fields.port = port.flatMap { Int($0) } ?? type.defaultPort
        return [candidate(fields: fields, relativePath: relativePath, key: selected.key, warnings: warnings)]
    }

    static func selectEnvironment(_ root: [String: Any]) -> (key: String, mapping: [String: Any])? {
        for name in preferredEnvironments {
            guard let mapping = YamlMappingSupport.mapping(root[name]) else {
                continue
            }
            if mapping["adapter"] != nil {
                return (name, mapping)
            }
            if let nested = firstNestedDatabase(mapping) {
                return ("\(name).\(nested.key)", nested.mapping)
            }
        }
        return nil
    }

    private static func firstNestedDatabase(_ mapping: [String: Any]) -> (key: String, mapping: [String: Any])? {
        for key in mapping.keys.sorted() {
            guard let nested = YamlMappingSupport.mapping(mapping[key]), nested["adapter"] != nil else {
                continue
            }
            return (key, nested)
        }
        return nil
    }

    private static func candidate(
        fields: ScannedConnectionFields,
        relativePath: String,
        key: String,
        warnings: [String]
    ) -> ScannedConnectionCandidate {
        ScannedConnectionCandidate(
            parsedURL: fields.toParsedConnectionURL(),
            sourceRelativePath: relativePath,
            sourceKey: key,
            kind: .railsDatabaseYaml,
            tier: .configFile,
            warnings: warnings
        )
    }

    private static func absoluteSQLitePath(_ path: String, projectRootURL: URL) -> String {
        guard !path.isEmpty else {
            return projectRootURL.appendingPathComponent("storage/development.sqlite3").path
        }
        guard !path.hasPrefix("/") else {
            return path
        }
        return projectRootURL.appendingPathComponent(path).standardizedFileURL.path
    }

    private static func adapterType(_ adapter: String) -> DatabaseType? {
        switch adapter.lowercased() {
        case "postgresql", "postgis", "postgres":
            return .postgresql
        case "mysql2", "mysql", "trilogy":
            return .mysql
        case "sqlite3", "sqlite":
            return .sqlite
        case "sqlserver":
            return .mssql
        default:
            return nil
        }
    }
}

struct ErbValueResolver {
    let environment: DotenvDocument?

    func resolve(_ value: String?, warnings: inout [String]) -> String? {
        guard let value else {
            return nil
        }
        guard value.contains("<%") else {
            return value
        }
        guard let name = environmentVariableName(in: value) else {
            warnings.append(unresolvedWarning)
            return nil
        }
        if let resolved = environment?[name] {
            return resolved
        }
        if let fallback = fallbackValue(in: value) {
            return fallback
        }
        warnings.append(unresolvedWarning)
        return nil
    }

    private var unresolvedWarning: String {
        String(localized: "Some values come from Ruby code and were not read")
    }

    private func environmentVariableName(in value: String) -> String? {
        guard let range = value.range(of: #"ENV(?:\.fetch)?\s*[\[(]\s*['"]([^'"]+)['"]"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(value[range])
        guard let quoteStart = matched.range(of: #"['"]"#, options: .regularExpression) else {
            return nil
        }
        let remainder = matched[quoteStart.upperBound...]
        guard let quoteEnd = remainder.range(of: #"['"]"#, options: .regularExpression) else {
            return nil
        }
        return String(remainder[remainder.startIndex..<quoteEnd.lowerBound])
    }

    private func fallbackValue(in value: String) -> String? {
        guard let range = value.range(of: #"ENV\.fetch\s*\(\s*['"][^'"]+['"]\s*,\s*['"]([^'"]*)['"]"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(value[range])
        guard let comma = matched.range(of: ",") else {
            return nil
        }
        let tail = matched[comma.upperBound...]
        guard let quoteStart = tail.range(of: #"['"]"#, options: .regularExpression) else {
            return nil
        }
        let remainder = tail[quoteStart.upperBound...]
        guard let quoteEnd = remainder.range(of: #"['"]"#, options: .regularExpression) else {
            return nil
        }
        return String(remainder[remainder.startIndex..<quoteEnd.lowerBound])
    }
}
