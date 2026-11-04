import Foundation

public struct DriverConnectionConfig: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let ssl: SSLConfiguration
    public let additionalFields: [String: String]

    /// Mints the password again for a sign-in the driver makes on its own after the first, such as
    /// a reconnect or the side connection that stops a query. Set when the password is a token that
    /// expires, which a later sign-in cannot reuse. It never waits on the main actor, so a driver may
    /// block one of its own dispatch queues on it.
    public let refreshPassword: (@Sendable () async throws -> String)?

    public init(
        host: String,
        port: Int,
        username: String,
        password: String,
        database: String,
        ssl: SSLConfiguration = SSLConfiguration(),
        additionalFields: [String: String] = [:],
        refreshPassword: (@Sendable () async throws -> String)? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.ssl = ssl
        self.additionalFields = additionalFields
        self.refreshPassword = refreshPassword
    }

    @_disfavoredOverload
    public init(
        host: String,
        port: Int,
        username: String,
        password: String,
        database: String,
        ssl: SSLConfiguration = SSLConfiguration(),
        additionalFields: [String: String] = [:]
    ) {
        self.init(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            ssl: ssl,
            additionalFields: additionalFields,
            refreshPassword: nil
        )
    }

    /// The password for a sign-in after the first: a fresh one when the password expires, the
    /// configured one otherwise.
    public func passwordForNewSignIn() async throws -> String {
        guard let refreshPassword else { return password }
        return try await refreshPassword()
    }
}

public extension DriverConnectionConfig {
    // A tunnel's forward is dialed on this Mac, so the certificate names the server behind it. Any other dial is
    // checked against its own host, whatever a stored or imported field says.
    var tunneledServerName: String? {
        guard ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()) else { return nil }
        let name = additionalFields["preTunnelHost"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}
