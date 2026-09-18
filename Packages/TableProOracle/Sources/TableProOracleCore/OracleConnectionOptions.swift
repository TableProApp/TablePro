import Foundation

public struct OracleConnectionOptions: Sendable, Equatable {
    public enum IdentifierMode: String, Sendable, Equatable, Codable, CaseIterable {
        case service
        case sid
    }

    /// The privilege the session is opened with. SYSDBA and SYSOPER are
    /// administrative logons that Oracle treats as a different identity from a
    /// normal connection by the same user.
    public enum Role: String, Sendable, Equatable, Codable, CaseIterable {
        case normal
        case sysdba
        case sysoper
    }

    /// The client's Oracle Native Network Encryption level, matching
    /// `SQLNET.ENCRYPTION_CLIENT`. Oracle's own clients default to `accepted`: they
    /// offer encryption without insisting on it, so a server that merely permits it
    /// stays in clear text while a server that requires it negotiates AES.
    ///
    /// - Note: The driver negotiates encryption and the data-integrity checksum in one
    ///         exchange and offers both at the same level, so this also sets what Oracle
    ///         configures separately as `SQLNET.CRYPTO_CHECKSUM_CLIENT`.
    public enum NetworkEncryption: String, Sendable, Equatable, Codable, CaseIterable {
        case rejected
        case accepted
        case requested
        case required
    }

    public enum AdditionalFieldKey {
        public static let connectionType = "oracleConnectionType"
        public static let serviceName = "oracleServiceName"
        public static let sid = "oracleSID"
        public static let role = "oracleRole"
        public static let networkEncryption = "oracleNetworkEncryption"
    }

    public static let defaultPort = 1_521
    public static let defaultLoginTimeoutSeconds: Double = 30

    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var database: String
    public var identifierMode: IdentifierMode
    public var serviceName: String
    public var sid: String
    public var role: Role
    public var tls: OracleTLSDescription
    public var networkEncryption: NetworkEncryption
    public var loginTimeoutSeconds: Double

    public init(
        host: String,
        port: Int = OracleConnectionOptions.defaultPort,
        user: String,
        password: String,
        database: String = "",
        identifierMode: IdentifierMode = .service,
        serviceName: String = "",
        sid: String = "",
        role: Role = .normal,
        tls: OracleTLSDescription = OracleTLSDescription(),
        networkEncryption: NetworkEncryption = .accepted,
        loginTimeoutSeconds: Double = OracleConnectionOptions.defaultLoginTimeoutSeconds
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.identifierMode = identifierMode
        self.serviceName = serviceName
        self.sid = sid
        self.role = role
        self.tls = tls
        self.networkEncryption = networkEncryption
        self.loginTimeoutSeconds = loginTimeoutSeconds
    }

    public var identifier: String {
        let chosen = identifierMode == .sid ? sid : serviceName
        return chosen.isEmpty ? database : chosen
    }

    public static func identifierMode(from additionalFields: [String: String]) -> IdentifierMode {
        IdentifierMode(rawValue: additionalFields[AdditionalFieldKey.connectionType] ?? "") ?? .service
    }

    public static func role(from additionalFields: [String: String]) -> Role {
        Role(rawValue: additionalFields[AdditionalFieldKey.role] ?? "") ?? .normal
    }

    public static func networkEncryption(from additionalFields: [String: String]) -> NetworkEncryption {
        NetworkEncryption(rawValue: additionalFields[AdditionalFieldKey.networkEncryption] ?? "") ?? .accepted
    }
}
