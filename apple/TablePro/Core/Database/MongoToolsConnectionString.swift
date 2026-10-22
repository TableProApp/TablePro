//
//  MongoToolsConnectionString.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum MongoToolsConnectionString {
    private static let defaultAuthenticationDatabase = "admin"

    // The driver refuses these mechanisms with any other auth database, as the plugin's resolver knows.
    private static let externalMechanisms: Set<String> = ["MONGODB-X509", "MONGODB-AWS"]

    // The tools' Go driver splits options on `;` as well as `&` and reads `+` as a space, so only RFC 3986 unreserved
    // characters stay raw.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static let fieldOwnedParameterKeys: Set<String> = [
        "authSource", "authMechanism", "replicaSet",
        "tls", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames", "tlsCAFile", "tlsCertificateKeyFile"
    ]

    // With TLS on, the SSL mode decides certificate checking, and the driver refuses a revocation switch beside the
    // `tlsInsecure` that already turns it off.
    private static let ownedByTLS = ["tlsInsecure"]
    private static let impliedByInsecure = ["tlsDisableOCSPEndpointCheck", "tlsDisableCertificateRevocationCheck"]

    static func make(for connection: DatabaseConnection, host: String) -> String {
        let scheme = connection.usesMongoSrv ? "mongodb+srv" : "mongodb"
        let base = "\(scheme)://\(userInfo(connection))\(hosts(connection, host: host))/"
        let query = parameters(connection)
        return query.isEmpty ? base : "\(base)?\(query.joined(separator: "&"))"
    }

    static func authenticationDatabase(for connection: DatabaseConnection) -> String {
        if let explicit = connection.mongoAuthSource {
            return explicit
        }
        if let mechanism = connection.mongoAuthMechanism, externalMechanisms.contains(mechanism.uppercased()) {
            return "$external"
        }
        guard !connection.usesMongoSrv, !connection.database.isEmpty else {
            return defaultAuthenticationDatabase
        }
        return connection.database
    }

    static func tlsParameters(for connection: DatabaseConnection) -> [String] {
        let ssl = connection.sslConfig
        guard ssl.isEnabled || connection.usesMongoSrv else { return [] }
        var parameters = ["tls=true"]
        if ssl.mode == .preferred || ssl.mode == .required {
            parameters.append("tlsInsecure=true")
        }
        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            parameters.append("tlsCAFile=\(encodedValue(ssl.caCertificatePath))")
        }
        if ssl.isEnabled, !ssl.clientCertificatePath.isEmpty {
            parameters.append("tlsCertificateKeyFile=\(encodedValue(ssl.clientCertificatePath))")
        }
        return parameters
    }

    private static func userInfo(_ connection: DatabaseConnection) -> String {
        guard !connection.username.isEmpty else { return "" }
        let encoded = connection.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
            ?? connection.username
        return "\(encoded)@"
    }

    private static func hosts(_ connection: DatabaseConnection, host: String) -> String {
        let listed = hostEntries(connection.additionalFields["mongoHosts"] ?? "")
        let entries = listed.isEmpty ? hostEntries(host) : listed
        if connection.usesMongoSrv, let srvName = entries.first {
            return encodedHost(srvName.host)
        }
        return entries
            .map { "\(encodedHost($0.host)):\($0.port.map(encodedValue) ?? String(connection.port))" }
            .joined(separator: ",")
    }

    private static func hostEntries(_ value: String) -> [(host: String, port: String?)] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(splitHostAndPort)
    }

    private static func splitHostAndPort(_ entry: String) -> (host: String, port: String?) {
        if entry.hasPrefix("["), let closing = entry.firstIndex(of: "]") {
            let remainder = entry[entry.index(after: closing)...]
            let port = remainder.hasPrefix(":") ? String(remainder.dropFirst()) : ""
            return (String(entry[...closing]), port.isEmpty ? nil : port)
        }
        // A bare IPv6 address has no port, and the driver reads it only in brackets.
        if entry.filter({ $0 == ":" }).count > 1 {
            return ("[\(entry)]", nil)
        }
        guard let colon = entry.lastIndex(of: ":") else { return (entry, nil) }
        let port = String(entry[entry.index(after: colon)...])
        return (String(entry[..<colon]), port.isEmpty ? nil : port)
    }

    private static func parameters(_ connection: DatabaseConnection) -> [String] {
        var parameters: [String] = []
        if !connection.username.isEmpty || connection.mongoAuthMechanism != nil {
            parameters.append("authSource=\(encodedValue(authenticationDatabase(for: connection)))")
        }
        if let mechanism = connection.mongoAuthMechanism {
            parameters.append("authMechanism=\(encodedValue(mechanism))")
        }
        if let replicaSet = connection.mongoReplicaSet {
            parameters.append("replicaSet=\(encodedValue(replicaSet))")
        }
        if let readPreference = connection.mongoReadPreference {
            parameters.append("readPreference=\(encodedValue(readPreference))")
        }
        if let writeConcern = connection.mongoWriteConcern {
            parameters.append("w=\(encodedValue(writeConcern))")
        }
        parameters.append(contentsOf: tlsParameters(for: connection))
        let setKeys = parameters.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        let tls = setKeys.contains("tls") ? ownedByTLS : []
        let implied = setKeys.contains("tlsInsecure") ? impliedByInsecure : []
        return parameters + extraParameters(connection, excluding: setKeys + fieldOwnedParameterKeys + tls + implied)
    }

    // The driver reads keys without case, so a typed parameter named like a field's key in any case is dropped.
    private static func extraParameters(_ connection: DatabaseConnection, excluding keys: [String]) -> [String] {
        var taken = Set(keys.map { $0.lowercased() })
        return connection.additionalFields
            .compactMap { key, value -> (String, String)? in
                guard key.hasPrefix("mongoParam_") else { return nil }
                let name = String(key.dropFirst("mongoParam_".count))
                guard !name.isEmpty else { return nil }
                return (name, value)
            }
            .sorted { $0.0 < $1.0 }
            .filter { taken.insert($0.0.lowercased()).inserted }
            .map { "\(encodedValue($0.0))=\(encodedValue($0.1))" }
    }

    private static func encodedHost(_ host: String) -> String {
        host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
    }

    private static func encodedValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }
}
