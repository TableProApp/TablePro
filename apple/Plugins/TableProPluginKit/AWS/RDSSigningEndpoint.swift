import Foundation

struct RDSSigningEndpoint: Equatable {
    let host: String
    let port: Int
}

// RDS validates the token against its own endpoint, while a tunnel or a port forward run outside
// TablePro makes the driver dial loopback. This picks the endpoint the token is signed for.
enum RDSSigningEndpointResolver {
    private static let loopbackHosts: Set<String> = ["localhost", "localhost.localdomain", "::1", "[::1]", "0.0.0.0"]

    static func resolve(
        configuredHost: String,
        configuredPort: Int,
        preTunnelHost: String?,
        preTunnelPort: Int?,
        override: String?,
        defaultPort: Int
    ) throws -> RDSSigningEndpoint {
        let dialsLoopback = isLoopback(configuredHost)

        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let endpoint = try parse(override, defaultPort: defaultPort)
            guard dialsLoopback || endpoint.host.caseInsensitiveCompare(configuredHost) == .orderedSame else {
                throw AWSAuthError.rdsEndpointUnresolved(host: configuredHost)
            }
            return endpoint
        }

        let host = dialsLoopback ? (preTunnelHost ?? configuredHost) : configuredHost
        let port = dialsLoopback ? (preTunnelPort ?? configuredPort) : configuredPort
        guard !isLoopback(host) else {
            throw AWSAuthError.rdsEndpointUnresolved(host: host)
        }
        return RDSSigningEndpoint(host: host.lowercased(), port: port)
    }

    static func parse(_ value: String, defaultPort: Int) throws -> RDSSigningEndpoint {
        var text = value.trimmingCharacters(in: .whitespaces)
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
        }
        if let slashIndex = text.firstIndex(of: "/") {
            text = String(text[..<slashIndex])
        }

        guard !text.isEmpty else { throw AWSAuthError.rdsEndpointInvalid(value) }

        guard let separatorIndex = text.lastIndex(of: ":") else {
            return try makeEndpoint(host: text, port: defaultPort, rawValue: value)
        }

        let portText = String(text[text.index(after: separatorIndex)...])
        guard let port = Int(portText), (1...65_535).contains(port) else {
            throw AWSAuthError.rdsEndpointInvalid(value)
        }
        return try makeEndpoint(host: String(text[..<separatorIndex]), port: port, rawValue: value)
    }

    static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        return loopbackHosts.contains(normalized) || normalized.hasPrefix("127.")
    }

    private static func makeEndpoint(host: String, port: Int, rawValue: String) throws -> RDSSigningEndpoint {
        let isHostname = !host.isEmpty
            && !host.contains(":")
            && host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        guard isHostname, !isLoopback(host) else {
            throw AWSAuthError.rdsEndpointInvalid(rawValue)
        }
        return RDSSigningEndpoint(host: host.lowercased(), port: port)
    }
}
