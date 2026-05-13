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
        loginTimeoutSeconds: Int = MSSQLConnectionOptions.defaultLoginTimeoutSeconds
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
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
    }

    static func schema(from additionalFields: [String: String]) -> String {
        let raw = additionalFields[AdditionalFieldKey.schema] ?? ""
        return raw.isEmpty ? defaultSchema : raw
    }
}
