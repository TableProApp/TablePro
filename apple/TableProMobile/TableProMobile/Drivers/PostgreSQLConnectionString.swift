import Foundation
import TableProSQLQuoting

nonisolated enum PostgreSQLConnectionString {
    static let connectTimeoutSeconds = 10
    static let clientEncoding = "UTF8"

    static func build(
        host: String,
        port: Int,
        database: String,
        user: String,
        password: String,
        ssl: DriverSSLConfiguration
    ) throws -> String {
        var parameters: [(String, String)] = endpoint(dialing: host, serverName: ssl.serverName) + [
            ("port", String(port)),
            ("dbname", database),
            ("user", user),
            ("password", password),
            ("connect_timeout", String(connectTimeoutSeconds)),
            ("sslmode", ssl.postgresSSLMode),
            ("client_encoding", clientEncoding),
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

        var pairs: [String] = []
        for (keyword, value) in parameters {
            let quoted: String
            do {
                quoted = try ConnectionStringQuoting.libpqValue(value)
            } catch {
                throw PostgreSQLError.connectionFailed(String(
                    format: String(localized: "The %@ setting holds a NUL character, which a PostgreSQL connection cannot carry."),
                    keyword
                ))
            }
            pairs.append("\(keyword)=\(quoted)")
        }
        return pairs.joined(separator: " ")
    }

    // libpq checks the certificate and sends SNI for `host`, and dials `hostaddr` without a lookup.
    private static func endpoint(dialing host: String, serverName: String?) -> [(String, String)] {
        guard let serverName, !serverName.isEmpty, serverName != host, isIPAddress(host) else {
            return [("host", host)]
        }
        return [("host", serverName), ("hostaddr", host)]
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }
}
