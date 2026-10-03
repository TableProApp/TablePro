//
//  LibPQConnectionString.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal struct LibPQConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 10_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int

    init(additionalFields: [String: String]) {
        milliseconds = Self.resolve(additionalFields: additionalFields)
    }

    init(milliseconds: Int) {
        self.milliseconds = min(max(milliseconds, 1), Self.maximumMilliseconds)
    }

    var nativeSeconds: Int {
        (milliseconds + 999) / 1_000
    }

    private static func resolve(additionalFields: [String: String]) -> Int {
        if let rawMilliseconds = additionalFields["connectTimeoutMilliseconds"],
           let parsedMilliseconds = Int64(rawMilliseconds.trimmingCharacters(in: .whitespaces)) {
            return clamp(parsedMilliseconds)
        }
        if let rawSeconds = additionalFields["connectTimeoutSeconds"],
           let parsedSeconds = Int64(rawSeconds.trimmingCharacters(in: .whitespaces)) {
            let multiplied = parsedSeconds.multipliedReportingOverflow(by: 1_000)
            let milliseconds = multiplied.overflow
                ? (parsedSeconds < 0 ? Int64.min : Int64.max)
                : multiplied.partialValue
            return clamp(milliseconds)
        }
        return defaultMilliseconds
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

/// One monotonic wall-clock budget for libpq's TCP/TLS/authentication and the bootstrap queries
/// that make the session usable. Keeping the absolute instant here prevents every catalog probe
/// from receiving the full timeout again.
internal struct LibPQConnectDeadline: Equatable, Sendable {
    private let expiresAtMicroseconds: Int64

    init(timeout: LibPQConnectTimeout, nowMicroseconds: Int64) {
        expiresAtMicroseconds = nowMicroseconds + Int64(timeout.milliseconds) * 1_000
    }

    func remainingMicroseconds(nowMicroseconds: Int64) -> Int64? {
        let remaining = expiresAtMicroseconds - nowMicroseconds
        return remaining > 0 ? remaining : nil
    }

    func nextPollDeadline(nowMicroseconds: Int64, maximumSliceMicroseconds: Int64) -> Int64? {
        guard remainingMicroseconds(nowMicroseconds: nowMicroseconds) != nil else { return nil }
        return min(expiresAtMicroseconds, nowMicroseconds + maximumSliceMicroseconds)
    }
}

internal enum LibPQConnectionString {
    static let clientEncoding = "UTF8"

    private static let clientEncodingNames: Set<String> = ["UTF8", "UNICODE"]

    static let sessionApplicationName = "TablePro"
    static let metadataApplicationName = "TablePro Metadata"

    static func build(
        host: String,
        port: Int,
        user: String,
        password: String?,
        database: String,
        sslConfig: SSLConfiguration,
        options: String?,
        applicationName: String? = nil,
        connectTimeoutSeconds: Int? = nil
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
        if let connectTimeoutSeconds {
            parameters.append(("connect_timeout", String(max(connectTimeoutSeconds, 1))))
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
        if let applicationName, !applicationName.isEmpty, !namesApplication(options) {
            parameters.append(("fallback_application_name", applicationName))
        }
        if let options, !options.isEmpty {
            parameters.append(("options", options))
        }

        return parameters
            .map { "\($0.0)='\(escape($0.1))'" }
            .joined(separator: " ")
    }

    static func applicationName(forPurpose purpose: String?) -> String {
        purpose == "metadata" ? metadataApplicationName : sessionApplicationName
    }

    /// libpq applies `fallback_application_name` over an `application_name` set in `options`, so a
    /// name the user already gave the session there has to keep the fallback out entirely.
    static func namesApplication(_ options: String?) -> Bool {
        guard let options else { return false }
        return settingNames(in: options).contains("application_name")
    }

    /// The setting each `-c name=value`, `-cname=value` and `--name=value` in `options` assigns, spelled
    /// the way the server reads a name: in any case, with `-` and `_` as the same character. Only the
    /// names, because a value such as `search_path=application_name` assigns something else.
    static func settingNames(in options: String) -> [String] {
        let tokens = options.split(whereSeparator: \.isWhitespace).map(String.init)
        var names: [String] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            let assignment: String?
            if token == "-c" {
                index += 1
                assignment = index < tokens.endIndex ? tokens[index] : nil
            } else if token.hasPrefix("--") {
                assignment = String(token.dropFirst(2))
            } else if token.hasPrefix("-c") {
                assignment = String(token.dropFirst(2))
            } else {
                assignment = nil
            }
            if let assignment, let name = assignment.split(separator: "=", maxSplits: 1).first {
                names.append(name.lowercased().replacingOccurrences(of: "-", with: "_"))
            }
            index += 1
        }
        return names
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
