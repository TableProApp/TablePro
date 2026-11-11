import Foundation

struct RDSSigningEndpoint: Equatable {
    let host: String
    let port: Int
}

// RDS validates the token against its own endpoint, while a tunnel or a port forward run outside
// TablePro makes the driver dial loopback. This picks the endpoint the token is signed for.
enum RDSSigningEndpointResolver {
    static func resolve(
        configuredHost: String,
        configuredPort: Int,
        preTunnelHost: String?,
        preTunnelPort: Int?,
        override: String?,
        defaultPort: Int
    ) throws -> RDSSigningEndpoint {
        let dialledHost = AWSEndpointHost.normalized(configuredHost)
        let dialsLoopback = AWSEndpointHost.isLoopback(configuredHost)

        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let endpoint = try parse(override, defaultPort: defaultPort)
            guard dialsLoopback || endpoint.host == dialledHost else {
                throw AWSAuthError.rdsEndpointNotDialed(endpoint: endpoint.host, host: dialledHost)
            }
            return endpoint
        }

        let host = dialsLoopback ? (preTunnelHost.map(AWSEndpointHost.normalized) ?? dialledHost) : dialledHost
        let port = dialsLoopback ? (preTunnelPort ?? configuredPort) : configuredPort
        guard !AWSEndpointHost.isLoopback(host) else {
            throw AWSAuthError.rdsEndpointUnresolved(host: host)
        }
        return RDSSigningEndpoint(host: host, port: port)
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

    private static func makeEndpoint(host: String, port: Int, rawValue: String) throws -> RDSSigningEndpoint {
        let name = AWSEndpointHost.normalized(host)
        let isHostname = !name.isEmpty
            && !name.contains(":")
            && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        guard isHostname, !AWSEndpointHost.isLoopback(name) else {
            throw AWSAuthError.rdsEndpointInvalid(rawValue)
        }
        return RDSSigningEndpoint(host: name, port: port)
    }
}
