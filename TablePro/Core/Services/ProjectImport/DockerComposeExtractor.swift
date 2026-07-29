//
//  DockerComposeExtractor.swift
//  TablePro
//

import Foundation

enum DockerComposeExtractor {
    struct ServiceDatabase {
        let type: DatabaseType
        let defaultPort: Int
    }

    static func extract(
        contents: String,
        relativePath: String,
        environment: DotenvDocument?
    ) -> [ScannedConnectionCandidate] {
        guard let parsed = YamlMappingSupport.loadMapping(contents),
              let root = ComposeInterpolator.interpolate(parsed, environment: environment) as? [String: Any],
              let services = YamlMappingSupport.mapping(root["services"]) else {
            return []
        }
        return services.keys.sorted().compactMap { name in
            guard let service = YamlMappingSupport.mapping(services[name]) else {
                return nil
            }
            return candidate(name: name, service: service, relativePath: relativePath)
        }
    }

    static func candidate(
        name: String,
        service: [String: Any],
        relativePath: String
    ) -> ScannedConnectionCandidate? {
        guard let image = YamlMappingSupport.string(service["image"]),
              let database = databaseKind(for: image) else {
            return nil
        }
        let variables = environmentVariables(service["environment"])
        var fields = ScannedConnectionFields(type: database.type)
        fields.host = "127.0.0.1"
        fields.connectionName = name
        applyCredentials(&fields, type: database.type, variables: variables)
        var warnings: [String] = []
        if [fields.username, fields.password, fields.database].contains(where: ComposeInterpolator.isUnresolved) {
            warnings.append(String(localized: "Some values are set outside this file"))
        }
        if let published = publishedPort(service["ports"], containerPort: database.defaultPort) {
            fields.port = published
        } else {
            fields.port = database.defaultPort
            warnings.append(String(
                localized: "No published port, may be unreachable"
            ))
        }
        return ScannedConnectionCandidate(
            parsedURL: fields.toParsedConnectionURL(),
            sourceRelativePath: relativePath,
            sourceKey: "services.\(name)",
            kind: .dockerCompose,
            tier: .configFile,
            warnings: warnings
        )
    }

    static func databaseKind(for image: String) -> ServiceDatabase? {
        let name = image.lowercased()
        if name.contains("postgres"), !name.contains("postgrest") {
            return ServiceDatabase(type: .postgresql, defaultPort: 5_432)
        }
        if name.contains("mariadb") {
            return ServiceDatabase(type: .mariadb, defaultPort: 3_306)
        }
        if name.contains("mysql") {
            return ServiceDatabase(type: .mysql, defaultPort: 3_306)
        }
        if name.contains("mongo") {
            return ServiceDatabase(type: .mongodb, defaultPort: 27_017)
        }
        if name.contains("redis") {
            return ServiceDatabase(type: .redis, defaultPort: 6_379)
        }
        if name.contains("clickhouse") {
            return ServiceDatabase(type: .clickhouse, defaultPort: 8_123)
        }
        if name.contains("mssql") || name.contains("sql-server") || name.contains("sqlserver") {
            return ServiceDatabase(type: .mssql, defaultPort: 1_433)
        }
        return nil
    }

    static func environmentVariables(_ value: Any?) -> [String: String] {
        if let mapping = value as? [String: Any] {
            return mapping.compactMapValues { YamlMappingSupport.string($0) }
        }
        guard let list = value as? [Any] else {
            return [:]
        }
        var variables: [String: String] = [:]
        for item in list {
            guard let text = YamlMappingSupport.string(item), let equals = text.firstIndex(of: "=") else {
                continue
            }
            let key = String(text[text.startIndex..<equals])
            let entry = String(text[text.index(after: equals)...])
            variables[key] = entry
        }
        return variables
    }

    static func publishedPort(_ value: Any?, containerPort: Int) -> Int? {
        guard let list = value as? [Any] else {
            return nil
        }
        for item in list {
            if let mapping = YamlMappingSupport.mapping(item) {
                guard YamlMappingSupport.int(mapping["target"]) == containerPort else {
                    continue
                }
                if let published = YamlMappingSupport.int(mapping["published"]) {
                    return published
                }
                continue
            }
            guard let text = YamlMappingSupport.string(item) else {
                continue
            }
            let segments = text.split(separator: ":").map(String.init)
            guard segments.count >= 2, Int(segments[segments.count - 1]) == containerPort else {
                continue
            }
            if let published = Int(segments[segments.count - 2]) {
                return published
            }
        }
        return nil
    }

    private static func applyCredentials(
        _ fields: inout ScannedConnectionFields,
        type: DatabaseType,
        variables: [String: String]
    ) {
        switch type {
        case .postgresql:
            fields.username = variables["POSTGRES_USER"] ?? "postgres"
            fields.password = variables["POSTGRES_PASSWORD"] ?? ""
            fields.database = variables["POSTGRES_DB"] ?? fields.username
        case .mariadb, .mysql:
            let prefix = variables["MARIADB_PASSWORD"] != nil || variables["MARIADB_DATABASE"] != nil
                ? "MARIADB"
                : "MYSQL"
            fields.username = variables["\(prefix)_USER"] ?? "root"
            fields.password = variables["\(prefix)_PASSWORD"] ?? variables["\(prefix)_ROOT_PASSWORD"] ?? ""
            fields.database = variables["\(prefix)_DATABASE"] ?? ""
        case .mongodb:
            fields.username = variables["MONGO_INITDB_ROOT_USERNAME"] ?? ""
            fields.password = variables["MONGO_INITDB_ROOT_PASSWORD"] ?? ""
            fields.database = variables["MONGO_INITDB_DATABASE"] ?? ""
        case .clickhouse:
            fields.username = variables["CLICKHOUSE_USER"] ?? "default"
            fields.password = variables["CLICKHOUSE_PASSWORD"] ?? ""
            fields.database = variables["CLICKHOUSE_DB"] ?? ""
        case .mssql:
            fields.username = "sa"
            fields.password = variables["MSSQL_SA_PASSWORD"] ?? variables["SA_PASSWORD"] ?? ""
        default:
            fields.password = variables["REDIS_PASSWORD"] ?? ""
        }
    }
}

enum ComposeInterpolator {
    static func interpolate(_ value: Any, environment: DotenvDocument?) -> Any {
        if let text = value as? String {
            return interpolate(text: text, environment: environment)
        }
        if let mapping = value as? [String: Any] {
            return mapping.mapValues { interpolate($0, environment: environment) }
        }
        if let list = value as? [Any] {
            return list.map { interpolate($0, environment: environment) }
        }
        return value
    }

    static func interpolate(text contents: String, environment: DotenvDocument?) -> String {
        guard contents.contains("$") else {
            return contents
        }
        var result = ""
        var remainder = Substring(contents)
        while let open = remainder.range(of: "${") {
            result += remainder[remainder.startIndex..<open.lowerBound]
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: "}") else {
                result += remainder[open.lowerBound...]
                return result
            }
            let reference = String(afterOpen[afterOpen.startIndex..<close])
            result += resolve(reference, environment: environment)
            remainder = afterOpen[afterOpen.index(after: close)...]
        }
        result += remainder
        return result
    }

    private static func resolve(_ reference: String, environment: DotenvDocument?) -> String {
        let separators = [":-", ":?", "-", "?"]
        for separator in separators {
            guard let range = reference.range(of: separator) else {
                continue
            }
            let name = String(reference[reference.startIndex..<range.lowerBound])
            let fallback = String(reference[range.upperBound...])
            guard !name.isEmpty else {
                continue
            }
            if let value = environment?[name] {
                return value
            }
            return separator.hasSuffix("?") ? unresolvedMarker(reference) : fallback
        }
        return environment?[reference] ?? unresolvedMarker(reference)
    }

    static func isUnresolved(_ value: String) -> Bool {
        value.contains("${")
    }

    private static func unresolvedMarker(_ reference: String) -> String {
        "${\(reference)}"
    }
}
