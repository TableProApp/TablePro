import Foundation

public struct OracleConnectionOptions: Sendable, Equatable {
    public enum IdentifierMode: String, Sendable, Equatable, Codable, CaseIterable {
        case service
        case sid
    }

    public enum AdditionalFieldKey {
        public static let connectionType = "oracleConnectionType"
        public static let serviceName = "oracleServiceName"
        public static let sid = "oracleSID"
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
    public var tls: OracleTLSDescription
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
        tls: OracleTLSDescription = OracleTLSDescription(),
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
        self.tls = tls
        self.loginTimeoutSeconds = loginTimeoutSeconds
    }

    public var identifier: String {
        let chosen = identifierMode == .sid ? sid : serviceName
        return chosen.isEmpty ? database : chosen
    }

    public static func identifierMode(from additionalFields: [String: String]) -> IdentifierMode {
        IdentifierMode(rawValue: additionalFields[AdditionalFieldKey.connectionType] ?? "") ?? .service
    }
}
