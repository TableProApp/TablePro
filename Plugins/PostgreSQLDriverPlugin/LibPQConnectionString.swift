//
//  LibPQConnectionString.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum LibPQConnectionString {
    static let clientEncoding = "UTF8"

    private static let clientEncodingNames: Set<String> = ["UTF8", "UNICODE"]

    static func build(
        host: String,
        port: Int,
        user: String,
        password: String?,
        database: String,
        sslConfig: SSLConfiguration,
        options: String?
    ) -> String {
        var parameters: [(String, String)] = [
            ("host", host),
            ("port", String(port)),
            ("dbname", database)
        ]

        if !user.isEmpty {
            parameters.append(("user", user))
        }
        if let password, !password.isEmpty {
            parameters.append(("password", password))
        }

        parameters.append(("sslmode", LibPQSSLMapping.sslmode(for: sslConfig.mode)))
        if sslConfig.verifiesCertificate, !sslConfig.caCertificatePath.isEmpty {
            parameters.append(("sslrootcert", sslConfig.caCertificatePath))
        }
        if !sslConfig.clientCertificatePath.isEmpty {
            parameters.append(("sslcert", sslConfig.clientCertificatePath))
        }
        if !sslConfig.clientKeyPath.isEmpty {
            parameters.append(("sslkey", sslConfig.clientKeyPath))
        }

        parameters.append(("client_encoding", clientEncoding))
        if let options, !options.isEmpty {
            parameters.append(("options", options))
        }

        return parameters
            .map { "\($0.0)='\(escape($0.1))'" }
            .joined(separator: " ")
    }

    static func isClientEncoding(reportedByServer reported: String?) -> Bool {
        guard let reported else { return false }
        return clientEncodingNames.contains(reported.uppercased())
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
