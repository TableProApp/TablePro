//
//  MongoToolsConnectionString.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
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
        let typed = MongoTypedParameters.sent(
            by: connection, besides: setKeys,
            tls: setKeys.contains("tls"), skipsVerification: setKeys.contains("tlsInsecure")
        )
        var options = typed
        MongoToolsConnectionString.applyKeychainSecrets(of: connection, to: &options)
        return parameters + options.map { "\(encodedValue($0.key))=\(encodedValue($0.value))" }
    }

    // The dump service puts the Keychain's passphrase and session token in the fields, as the driver gets them; the
    // string goes only into the tools' private configuration file.
    private static func applyKeychainSecrets(of connection: DatabaseConnection, to options: inout [(key: String, value: String)]) {
        let ssl = connection.sslConfig
        if ssl.isEnabled, !ssl.clientCertificatePath.isEmpty,
           let passphrase = connection.additionalFields["sslClientKeyPassphrase"], !passphrase.isEmpty {
            options.append((key: "tlsCertificateKeyFilePassword", value: passphrase))
        }
        guard connection.mongoAuthMechanism?.uppercased() == "MONGODB-AWS",
              let token = connection.additionalFields[ConnectionSecretOptions.mongoSessionTokenFieldId], !token.isEmpty
        else { return }
        let current = options.first { $0.key.lowercased() == "authmechanismproperties" }?.value
        options.removeAll { $0.key.lowercased() == "authmechanismproperties" }
        options.append((key: "authMechanismProperties", value: ConnectionSecretOptions.joiningSessionToken(token, to: current)))
    }

    private static func encodedHost(_ host: String) -> String {
        host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
    }

    private static func encodedValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }
}
