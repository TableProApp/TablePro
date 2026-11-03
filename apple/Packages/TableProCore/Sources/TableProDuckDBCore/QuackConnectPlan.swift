import Foundation
import TableProSQLQuoting

/// What a remote DuckDB connection's fields say, as stored.
public struct QuackConnectRequest: Sendable, Equatable {
    public var host: String
    public var port: String
    public var alias: String
    public var token: String
    public var sslMode: String?
    public var caCertificatePath: String?
    public var certificateFingerprint: String?
    /// The server's own host when `host` and `port` are a tunnel's loopback forward, else nil.
    public var tunneledServerHost: String?

    public init(
        host: String,
        port: String = "",
        alias: String = "",
        token: String = "",
        sslMode: String? = nil,
        caCertificatePath: String? = nil,
        certificateFingerprint: String? = nil,
        tunneledServerHost: String? = nil
    ) {
        self.host = host
        self.port = port
        self.alias = alias
        self.token = token
        self.sslMode = sslMode
        self.caCertificatePath = caCertificatePath
        self.certificateFingerprint = certificateFingerprint
        self.tunneledServerHost = tunneledServerHost
    }
}

/// The statements that attach a Quack server, in the order they run, or the reason they cannot.
///
/// Every refusal is thrown from `init`, so it reaches the user before the in-memory instance opens, the
/// extensions download or anything dials the server.
public struct QuackConnectPlan: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Runs through `QuackExtensionLoader.load`.
        case loadExtension(String)
        /// The user's CA file. The caller builds the bundle with `QuackTrustBundle.combined`, writes it,
        /// and runs `setCACertFileStatement(bundlePath:)` with the path it wrote.
        case trustCACertificate(path: String)
        case statement(String)
    }

    public static let defaultPort = 9_494
    public static let defaultAlias = "remotedb"
    public static let secretName = "tablepro_quack"

    public let alias: String
    public let mode: QuackSSLMode
    public let isTunneled: Bool
    public let steps: [Step]

    public init(_ request: QuackConnectRequest) throws {
        let host = request.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw QuackConnectError.missingHost }
        // Every Quack server has a token, and the client refuses to connect without one.
        guard !request.token.isEmpty else { throw QuackConnectError.missingToken }
        guard let port = Self.port(from: request.port) else { throw QuackConnectError.invalidPort }
        let aliasInput = request.alias.trimmingCharacters(in: .whitespaces)
        let alias = aliasInput.isEmpty ? Self.defaultAlias : aliasInput
        let mode = QuackSSLMode(fieldValue: request.sslMode)

        // PluginKit's test for a forward reads the built-in host, which DuckDB leaves at localhost, so it
        // passes on a direct dial too. A forward is always dialed on the loopback, so a server name that
        // comes with any other dial is ignored.
        let serverHost = request.tunneledServerHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tunneledServer: String? = (!serverHost.isEmpty && QuackHost.isLocal(host)) ? serverHost : nil

        var steps: [Step] = [.loadExtension("quack")]
        var options: [String] = []
        if !request.token.isEmpty {
            options.append("SECRET \(Self.secretName)")
        }

        switch mode {
        case .automatic:
            if let tunneledServer {
                // Quack picks plain HTTP for a local host and HTTPS checked against the system bundle and
                // the host name for any other. The loopback is always local to it, so its rule is applied
                // here to the server's own name. HTTPS that way would check the certificate against
                // 127.0.0.1 and fail, so a non-local server needs a mode that does not check the name.
                guard QuackHost.isLocal(tunneledServer) else {
                    throw QuackConnectError.tunneledAutomatic(server: tunneledServer)
                }
                options.append("DISABLE_SSL true")
            }
            // A direct dial names no option, so Quack's own rule applies, which is what every connection
            // saved before SSL Mode existed did.
        case .disabled:
            options.append("DISABLE_SSL true")
        case .required:
            // httpfs's settings exist only once it is loaded. Elsewhere the ATTACH loads httpfs itself
            // when its transport needs it. GLOBAL for the reason `setCACertFileStatement` gives; httpfs has
            // no per-host switch, so the editor's own HTTPS reads on this connection go unchecked too.
            steps.append(.loadExtension("httpfs"))
            steps.append(.statement("SET GLOBAL enable_curl_server_cert_verification = false"))
            options.append("DISABLE_SSL false")
        case .verifyIdentity:
            // curl checks the name the URL dials, which through a forward is 127.0.0.1, never the server's.
            guard tunneledServer == nil else { throw QuackConnectError.tunneledVerifyIdentity }
            let caPath = request.caCertificatePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !caPath.isEmpty {
                steps.append(.loadExtension("httpfs"))
                steps.append(.trustCACertificate(path: caPath))
            }
            options.append("DISABLE_SSL false")
        case .verifyFingerprint:
            // The pinned client is Quack's own and never loads httpfs, so no httpfs step: a pin keeps
            // working on a Mac that cannot download it.
            let fingerprint = try QuackCertificateFingerprint.normalized(request.certificateFingerprint ?? "")
            options.append("DISABLE_SSL false")
            options.append("SSL_FINGERPRINT \(SQLQuoting.stringLiteral(fingerprint))")
        }

        steps.append(.statement(Self.secretStatement(token: request.token)))
        steps.append(.statement(Self.attachStatement(host: host, port: port, alias: alias, options: options)))
        steps.append(.statement(Self.dropSecretStatement))
        steps.append(.statement(Self.useStatement(alias: alias)))

        self.alias = alias
        self.mode = mode
        self.isTunneled = tunneledServer != nil
        self.steps = steps
    }

    /// GLOBAL because each connect opens its own in-memory instance, so it reaches no other connection,
    /// and a heartbeat that opens a new pooled client reads global values, not this session's.
    public static func setCACertFileStatement(bundlePath: String) -> String {
        "SET GLOBAL ca_cert_file = \(SQLQuoting.stringLiteral(bundlePath))"
    }

    /// The token goes in a secret rather than an ATTACH `TOKEN` option, which `duckdb_databases()` shows in
    /// plain text to every statement the session runs. The session opens with persistent secrets off, so
    /// this is the only secret ATTACH can find, for the token and for a fingerprint alike.
    static func secretStatement(token: String) -> String {
        "CREATE OR REPLACE TEMPORARY SECRET \(secretName) (TYPE quack, TOKEN \(SQLQuoting.stringLiteral(token)))"
    }

    /// ATTACH keeps the token in the catalog it creates, so the secret is dropped as soon as ATTACH
    /// returns. Left in place, a later `ATTACH` in the editor or from an AI client found it by scope and
    /// sent this server's token to the host it named, and a scope does not stop that: DuckDB matches a
    /// scope as a prefix, so `quack:localhost:5000` also reaches `quack:localhost:50000` (both measured).
    static let dropSecretStatement = "DROP TEMPORARY SECRET \(secretName)"

    static func attachStatement(host: String, port: Int, alias: String, options: [String]) -> String {
        let uri = "quack:\(QuackHost.uriHost(host)):\(port)"
        let attach = "ATTACH \(SQLQuoting.stringLiteral(uri)) AS \(SQLQuoting.identifier(alias))"
        guard !options.isEmpty else { return attach }
        return "\(attach) (\(options.joined(separator: ", ")))"
    }

    static func useStatement(alias: String) -> String {
        "USE \(SQLQuoting.identifier(alias))"
    }

    static func port(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return defaultPort }
        guard let port = Int(trimmed), (1...65_535).contains(port) else { return nil }
        return port
    }
}

enum QuackHost {
    /// Quack's own set of local hosts, which it dials over plain HTTP by default
    /// (`QuackUri::IsLocal`, quack_uri.hpp:51-53 at f96420ed).
    static func isLocal(_ host: String) -> Bool {
        let bare = unbracketed(host)
        return bare.lowercased() == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// Quack reads the first colon after the host as the start of the port, so an IPv6 literal typed
    /// without brackets failed with "Invalid Port".
    static func uriHost(_ host: String) -> String {
        guard !host.hasPrefix("["), host.filter({ $0 == ":" }).count >= 2 else { return host }
        return "[\(host)]"
    }

    private static func unbracketed(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }
}
