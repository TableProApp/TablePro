import Foundation

public struct MSSQLConnectionOptions: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var database: String
    public var schema: String
    public var encryptionFlag: String
    public var applicationName: String
    public var loginTimeoutSeconds: Int
    public var authMethod: MSSQLAuthMethod
    public var kerberosCachePath: String?
    public var kerberosServicePrincipal: String?

    /// How far to check the server certificate. Set after init by the plugin from the
    /// connection's SSL mode, so the existing initializer keeps its signature.
    public var certificateVerification: MSSQLCertificateVerification = .none
    public var caCertificatePath: String?

    /// Microsoft Entra ID access token, sent in place of a user name and password. Set after
    /// init for the same reason as `certificateVerification`. Only read when
    /// `authMethod == .entra`.
    public var fedAuthToken: String?

    public static let defaultPort = 1433
    public static let defaultSchema = "dbo"
    public static let defaultApplicationName = "TablePro"
    public static let defaultEncryptionFlag = "off"
    public static let defaultLoginTimeoutSeconds = 30

    public init(
        host: String,
        port: Int = MSSQLConnectionOptions.defaultPort,
        user: String,
        password: String,
        database: String,
        schema: String = MSSQLConnectionOptions.defaultSchema,
        encryptionFlag: String = MSSQLConnectionOptions.defaultEncryptionFlag,
        applicationName: String = MSSQLConnectionOptions.defaultApplicationName,
        loginTimeoutSeconds: Int = MSSQLConnectionOptions.defaultLoginTimeoutSeconds,
        authMethod: MSSQLAuthMethod = .sqlServer,
        kerberosCachePath: String? = nil,
        kerberosServicePrincipal: String? = nil
    ) {
        self.host = host
        self.port = port
        self.authMethod = authMethod
        self.kerberosCachePath = kerberosCachePath
        self.kerberosServicePrincipal = kerberosServicePrincipal
        switch authMethod {
        case .sqlServer:
            self.user = user
            self.password = password
        case .windows, .entra:
            self.user = ""
            self.password = ""
        }
        self.database = database
        self.schema = schema
        self.encryptionFlag = encryptionFlag
        self.applicationName = applicationName
        self.loginTimeoutSeconds = loginTimeoutSeconds
    }
}

public extension MSSQLConnectionOptions {
    enum AdditionalFieldKey {
        public static let schema = "mssqlSchema"
        public static let authMethod = "mssqlAuthMethod"
    }

    static func schema(from additionalFields: [String: String]) -> String {
        let raw = additionalFields[AdditionalFieldKey.schema] ?? ""
        return raw.isEmpty ? defaultSchema : raw
    }

    static func authMethod(from additionalFields: [String: String]) -> MSSQLAuthMethod {
        MSSQLAuthMethod(rawValue: additionalFields[AdditionalFieldKey.authMethod] ?? "") ?? .sqlServer
    }
}
