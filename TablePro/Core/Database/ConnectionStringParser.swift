import Foundation

struct ParsedConnection: Equatable {
    let type: DatabaseType
    let host: String
    let port: Int
    let username: String?
    let password: String?
    let database: String?
    let useSSL: Bool
    let rawScheme: String
    let queryParameters: [String: String]
}

enum ConnectionStringParserError: Error, LocalizedError, Equatable {
    case unsupportedScheme(String)
    case malformedURL

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return String(format: String(localized: "Unsupported connection scheme: %@"), scheme)
        case .malformedURL:
            return String(localized: "The text doesn't look like a connection URL.")
        }
    }
}

enum ConnectionStringParser {
    static func parse(_ string: String) throws -> ParsedConnection {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectionStringParserError.malformedURL
        }

        guard let schemeRange = trimmed.range(of: "://") else {
            throw ConnectionStringParserError.malformedURL
        }
        let rawScheme = String(trimmed[trimmed.startIndex..<schemeRange.lowerBound]).lowercased()

        guard let descriptor = SchemeDescriptor.match(rawScheme: rawScheme) else {
            throw ConnectionStringParserError.unsupportedScheme(rawScheme)
        }

        let normalized = normalizeForFoundationURL(trimmed, descriptor: descriptor)
        guard let components = URLComponents(string: normalized) else {
            throw ConnectionStringParserError.malformedURL
        }

        let host = components.host ?? ""
        guard !host.isEmpty else {
            throw ConnectionStringParserError.malformedURL
        }
        let port: Int
        if let explicit = components.port {
            guard (1...65_535).contains(explicit) else {
                throw ConnectionStringParserError.malformedURL
            }
            port = explicit
        } else if rawScheme == "mongodb+srv" {
            port = 0
        } else {
            port = descriptor.defaultPort
        }

        let username = components.user.flatMap { $0.removingPercentEncoding ?? $0 }
        let password = components.password.flatMap { $0.removingPercentEncoding ?? $0 }

        let path = components.path
        let database: String?
        if path.isEmpty || path == "/" {
            database = nil
        } else {
            let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            database = trimmedPath.isEmpty ? nil : trimmedPath
        }

        let queryParameters = decodeQueryItems(components.queryItems)
        let useSSL = resolveUseSSL(
            descriptor: descriptor,
            queryParameters: queryParameters
        )

        return ParsedConnection(
            type: descriptor.databaseType,
            host: host,
            port: port,
            username: username?.nilIfEmpty,
            password: password?.nilIfEmpty,
            database: database,
            useSSL: useSSL,
            rawScheme: rawScheme,
            queryParameters: queryParameters
        )
    }

    // MARK: - Helpers

    private static func decodeQueryItems(_ items: [URLQueryItem]?) -> [String: String] {
        var result: [String: String] = [:]
        guard let items else { return result }
        for item in items {
            guard let value = item.value else { continue }
            let decoded = value.removingPercentEncoding ?? value
            result[item.name] = decoded
        }
        return result
    }

    private static func resolveUseSSL(
        descriptor: SchemeDescriptor,
        queryParameters: [String: String]
    ) -> Bool {
        if descriptor.forcesSSL { return true }

        if descriptor.databaseType == .postgresql,
           let sslMode = queryParameters["sslmode"]?.lowercased() {
            return ["require", "verify-ca", "verify-full"].contains(sslMode)
        }

        if let sslParam = queryParameters["ssl"]?.lowercased() {
            return sslParam == "true" || sslParam == "1" || sslParam == "require"
        }

        return descriptor.defaultUseSSL
    }

    private static func normalizeForFoundationURL(
        _ original: String,
        descriptor: SchemeDescriptor
    ) -> String {
        guard let schemeRange = original.range(of: "://") else { return original }
        let remainder = String(original[schemeRange.upperBound...])
        return descriptor.foundationScheme + "://" + remainder
    }
}

private struct SchemeDescriptor {
    let rawScheme: String
    let foundationScheme: String
    let databaseType: DatabaseType
    let defaultPort: Int
    let defaultUseSSL: Bool
    let forcesSSL: Bool

    static func match(rawScheme: String) -> SchemeDescriptor? {
        switch rawScheme {
        case "postgres", "postgresql":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .postgresql,
                defaultPort: 5_432,
                defaultUseSSL: false,
                forcesSSL: false
            )
        case "mysql":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .mysql,
                defaultPort: 3_306,
                defaultUseSSL: false,
                forcesSSL: false
            )
        case "redis":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .redis,
                defaultPort: 6_379,
                defaultUseSSL: false,
                forcesSSL: false
            )
        case "rediss":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .redis,
                defaultPort: 6_379,
                defaultUseSSL: true,
                forcesSSL: true
            )
        case "mongodb":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .mongodb,
                defaultPort: 27_017,
                defaultUseSSL: false,
                forcesSSL: false
            )
        case "mongodb+srv":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .mongodb,
                defaultPort: 27_017,
                defaultUseSSL: true,
                forcesSSL: true
            )
        case "sqlite":
            return SchemeDescriptor(
                rawScheme: rawScheme,
                foundationScheme: "https",
                databaseType: .sqlite,
                defaultPort: 0,
                defaultUseSSL: false,
                forcesSSL: false
            )
        default:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
