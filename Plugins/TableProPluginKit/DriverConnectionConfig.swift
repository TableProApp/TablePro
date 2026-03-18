import Foundation

public struct DriverConnectionConfig: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String
    public let additionalFields: [String: String]

    public init(
        host: String,
        port: Int,
        username: String,
        password: String,
        database: String,
        additionalFields: [String: String] = [:]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.additionalFields = additionalFields
    }
}
