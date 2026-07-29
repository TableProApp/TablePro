//
//  RDSSigningEndpoint.swift
//  TablePro
//
//  An RDS IAM token is a SigV4 presigned URL whose signature covers the DB
//  endpoint's host and port, and RDS validates it against its own endpoint. The
//  socket the driver dials is not always that endpoint: a tunnel points it at
//  loopback, and so does a port forward the user runs outside TablePro. This
//  resolves the endpoint the token must be signed for.
//

import Foundation
import TableProPluginKit

struct RDSSigningEndpoint: Equatable {
    let host: String
    let port: Int
}

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
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return try parse(override, defaultPort: defaultPort)
        }

        let host = preTunnelHost ?? configuredHost
        let port = preTunnelPort ?? configuredPort
        guard !isLoopback(host) else {
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
        return RDSSigningEndpoint(host: host, port: port)
    }
}
