//
//  SurrealDBConnectionConfig.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

public enum SurrealAuthLevel: String, Sendable, CaseIterable {
    case root
    case namespace
    case database
    case record
    case token

    public var usesCredentials: Bool {
        self != .token
    }
}

public struct SurrealDBConnectionConfig: Sendable {
    public static let authLevelField = "sdbAuthLevel"
    public static let tokenField = "sdbToken"
    public static let databaseField = "sdbDatabase"
    public static let accessField = "sdbAccess"
    public static let skipTLSVerifyField = "sdbSkipTLSVerify"

    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let namespace: String
    public let database: String
    public let authLevel: SurrealAuthLevel
    public let token: String
    public let access: String
    public let useTLS: Bool
    public let skipTLSVerify: Bool

    public init(config: DriverConnectionConfig) {
        let fields = config.additionalFields
        self.host = config.host
        self.port = config.port > 0 ? config.port : 8000
        self.username = config.username
        self.password = config.password
        self.namespace = config.database
        self.database = fields[Self.databaseField]?.trimmingCharacters(in: .whitespaces) ?? ""
        self.authLevel = SurrealAuthLevel(rawValue: fields[Self.authLevelField] ?? "") ?? .root
        self.token = fields[Self.tokenField] ?? ""
        self.access = fields[Self.accessField] ?? ""
        self.useTLS = config.ssl.isEnabled
        self.skipTLSVerify = fields[Self.skipTLSVerifyField] == "true"
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
    }

    public var baseURL: URL? {
        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = host
        components.port = port
        return components.url
    }

    public func validate() throws {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SurrealDBError.missingField(String(localized: "Host"))
        }
        switch authLevel {
        case .token:
            guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SurrealDBError.missingField(String(localized: "Token"))
            }
        case .namespace:
            guard !namespace.isEmpty else {
                throw SurrealDBError.missingField(String(localized: "Namespace"))
            }
        case .database, .record:
            guard !namespace.isEmpty else {
                throw SurrealDBError.missingField(String(localized: "Namespace"))
            }
            guard !database.isEmpty else {
                throw SurrealDBError.missingField(String(localized: "Database"))
            }
            if authLevel == .record, access.trimmingCharacters(in: .whitespaces).isEmpty {
                throw SurrealDBError.missingField(String(localized: "Access Method"))
            }
        case .root:
            break
        }
    }
}

public enum SurrealServerVersion {
    public static func parse(_ raw: String) -> (major: Int, minor: Int)? {
        let scalars = raw.drop { !$0.isNumber }
        let parts = scalars.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]) else { return nil }
        let minorDigits = parts[1].prefix { $0.isNumber }
        guard let minor = Int(minorDigits) else { return nil }
        return (major, minor)
    }

    public static func isSupported(_ raw: String) -> Bool {
        guard let version = parse(raw) else { return true }
        return version.major >= 2
    }
}
