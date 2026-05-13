import Foundation

public struct DriverConnectionConfig: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let ssl: SSLConfiguration
    public let additionalFields: [String: String]

    public init(
        host: String,
        port: Int,
        username: String,
        password: String,
        database: String,
        ssl: SSLConfiguration = SSLConfiguration(),
        additionalFields: [String: String] = [:]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.ssl = ssl
        self.additionalFields = additionalFields
    }
}
