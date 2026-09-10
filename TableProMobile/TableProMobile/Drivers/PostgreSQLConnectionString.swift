import Foundation

nonisolated enum PostgreSQLConnectionString {
    static let connectTimeoutSeconds = 10

    static func build(
        host: String,
        port: Int,
        database: String,
        user: String,
        password: String,
        ssl: DriverSSLConfiguration
    ) -> String {
        var parameters: [(String, String)] = [
            ("host", host),
            ("port", String(port)),
            ("dbname", database),
            ("user", user),
            ("password", password),
            ("connect_timeout", String(connectTimeoutSeconds)),
            ("sslmode", ssl.postgresSSLMode),
        ]

        if let caPath = ssl.existingCACertificatePath {
            parameters.append(("sslrootcert", caPath))
        }
        if let clientCertPath = ssl.existingClientCertificatePath {
            parameters.append(("sslcert", clientCertPath))
        }
        if let clientKeyPath = ssl.existingClientKeyPath {
            parameters.append(("sslkey", clientKeyPath))
        }

        return parameters
            .map { "\($0.0)='\(escape($0.1))'" }
            .joined(separator: " ")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
