//
//  MongoDBConnectionURI.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated struct MongoDBURIOption: Equatable, Sendable {
    let key: String
    let value: String
}

nonisolated struct MongoDBConnectionURI: Sendable {
    let useSrv: Bool
    let host: String
    let port: Int
    let user: String
    let password: String?
    let database: String
    let options: [MongoDBURIOption]

    // libmongoc splits options on a raw `&` and decodes every value, and the Go tools also split on `;` and read `+` as a
    // space, so only RFC 3986 unreserved characters stay raw. Not `.alphanumerics`, which holds non-ASCII letters.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    var text: String {
        let scheme = useSrv ? "mongodb+srv" : "mongodb"
        let encodedDb = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database
        let path = database.isEmpty ? "/" : "/\(encodedDb)"
        let query = options.map { "\(Self.encoded($0.key))=\(Self.encoded($0.value))" }.joined(separator: "&")
        return "\(scheme)://\(userInfo)\(hosts)\(path)?\(query)"
    }

    private var userInfo: String {
        guard !user.isEmpty else { return "" }
        let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
        guard let password, !password.isEmpty else { return "\(encodedUser)@" }
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        return "\(encodedUser):\(encodedPassword)@"
    }

    private var hosts: String {
        if useSrv {
            let srvHost = MongoDBConnection.stripPort(fromSrvHost: host)
            return srvHost.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? srvHost
        }
        if let hosts = MongoDBHostList.uriHosts(host, defaultPort: port) {
            return hosts
        }
        guard host.contains(",") else {
            let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
            return "\(encodedHost):\(port)"
        }
        // A list MongoDBHostList cannot read is passed on for libmongoc to refuse, with its ports encoded so a typed
        // `/?` cannot start the options.
        let segments = host.split(separator: ",").compactMap { segment -> String? in
            let parts = segment.split(separator: ":", maxSplits: 1)
            guard let first = parts.first else { return nil }
            let name = String(first).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
            guard parts.count > 1 else { return "\(encodedName):\(port)" }
            return "\(encodedName):\(Self.encoded(parts[1].trimmingCharacters(in: .whitespaces)))"
        }
        return segments.isEmpty ? "localhost:\(port)" : segments.joined(separator: ",")
    }

    // The fields own their keys, and a typed parameter named like one is dropped rather than sent after it, where
    // libmongoc would let it win. Keys compare without case, as libmongoc reads them.
    static func options(
        connectTimeout: MongoDBConnectTimeout,
        authSource: String,
        ssl: [MongoDBURIOption],
        readPreference: String?,
        writeConcern: String?,
        authMechanism: String?,
        replicaSet: String?,
        extraParams: [String: String]
    ) -> [MongoDBURIOption] {
        var options = connectTimeout.uriOptions
        options.append(MongoDBURIOption(key: "authSource", value: authSource))
        options += ssl
        let typed: [(key: String, value: String?)] = [
            ("readPreference", readPreference),
            ("w", writeConcern),
            ("authMechanism", authMechanism),
            ("replicaSet", replicaSet)
        ]
        for (key, value) in typed {
            guard let value, !value.isEmpty else { continue }
            options.append(MongoDBURIOption(key: key, value: value))
        }

        var taken = Set(fieldOwnedKeys.map { $0.lowercased() })
        taken.formUnion(options.map { $0.key.lowercased() })
        // With TLS on, the SSL mode decides certificate checking, and libmongoc refuses a revocation switch beside the
        // `tlsAllowInvalidCertificates` that already turns it off.
        if !ssl.isEmpty {
            taken.insert("tlsinsecure")
        }
        if ssl.contains(where: { $0.key == "tlsAllowInvalidCertificates" }) {
            taken.formUnion(["tlsdisableocspendpointcheck", "tlsdisablecertificaterevocationcheck"])
        }
        for key in extraParams.keys.sorted() where taken.insert(key.lowercased()).inserted {
            options.append(MongoDBURIOption(key: key, value: extraParams[key] ?? ""))
        }
        return options
    }

    static let fieldOwnedKeys = [
        "connectTimeoutMS", "serverSelectionTimeoutMS",
        "authSource", "authMechanism", "replicaSet",
        "tls", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames",
        "tlsCAFile", "tlsCertificateKeyFile"
    ]
}
