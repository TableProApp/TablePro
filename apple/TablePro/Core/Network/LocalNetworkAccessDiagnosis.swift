//
//  LocalNetworkAccessDiagnosis.swift
//  TablePro
//

import Foundation
import Network
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

/// An error that knows whether it was raised before any socket opened. One that was cannot be a
/// network refusal, whatever a probe of the host says.
internal protocol ConnectionPreflightReporting {
    var failedBeforeDialing: Bool { get }
}

internal struct LocalNetworkHop: Equatable, Sendable {
    internal enum Role: Equatable, Sendable {
        case database
        case sshServer
        case sshJumpHost
        case socksProxy
    }

    internal let role: Role
    internal let host: String
}

/// A connect the Local Network permission refused. The driver only saw an unreachable host, so its
/// error is kept for Copy Details while this one names the cause.
internal struct LocalNetworkAccessError: Error, LocalizedError {
    internal let hop: LocalNetworkHop
    internal let underlying: any Error

    internal var errorDescription: String? {
        let format: String
        switch hop.role {
        case .database:
            format = String(localized: "TablePro does not have Local Network access, so it cannot reach the database at %@.")
        case .sshServer:
            format = String(localized: "TablePro does not have Local Network access, so it cannot reach the SSH server at %@.")
        case .sshJumpHost:
            format = String(localized: "TablePro does not have Local Network access, so it cannot reach the SSH jump host at %@.")
        case .socksProxy:
            format = String(localized: "TablePro does not have Local Network access, so it cannot reach the SOCKS proxy at %@.")
        }
        return String(format: format, hop.host)
    }

    internal var recoverySuggestion: String? {
        String(localized: "Turn on TablePro in System Settings > Privacy & Security > Local Network, then try again.")
    }
}

internal enum LocalNetworkAccessDiagnosis {
    /// A failure that already names its fix, or that the user chose, gains nothing from a probe.
    /// `fields` is the connection's `additionalFields`, which decide whether a sign-in claims the error.
    internal static func canExplain(_ error: Error, fields: [String: String]) -> Bool {
        if error is LocalNetworkAccessError || error is SSLHandshakeError { return false }
        if let preflight = error as? ConnectionPreflightReporting, preflight.failedBeforeDialing { return false }
        if ConnectionFailureClassifier.isUserCancelled(error) || DatabaseCancellationDiagnosis.isCancellation(error) {
            return false
        }
        if ConnectionSignInRegistry.provider(for: error, fields: fields) != nil { return false }
        return ConnectionFailureClassifier.recoveryAction(for: error) == nil
    }

    /// The hosts this Mac opens a socket to. Behind a tunnel or a proxy that is the first hop only,
    /// since the server behind it is dialed from the other end.
    internal static func hops(for connection: DatabaseConnection, sshDocument: SSHConfigDocument) -> [LocalNetworkHop] {
        let kinds = connection.enabledTunnelKinds
        guard kinds.count <= 1 else { return [] }

        let candidates: [LocalNetworkHop]
        switch kinds.first {
        case nil:
            candidates = directHosts(of: connection).map { LocalNetworkHop(role: .database, host: $0) }
        case .ssh, .remoteFile, .remoteDatabaseSession:
            guard let first = LibSSH2TunnelFactory.firstHop(of: connection.resolvedSSHConfig, document: sshDocument) else {
                return []
            }
            candidates = [LocalNetworkHop(role: first.isJumpHost ? .sshJumpHost : .sshServer, host: first.host)]
        case .socksProxy:
            candidates = connection.resolvedSOCKSProxyConfig.map { [LocalNetworkHop(role: .socksProxy, host: $0.host)] } ?? []
        case .cloudflare, .cloudSQLProxy, .tunnelCommand:
            // A helper process dials a cloud endpoint, or whatever the user's command names.
            candidates = []
        }

        var seen: Set<String> = []
        return candidates.compactMap { hop in
            let host = normalized(hop.host)
            guard !host.isEmpty, !host.hasPrefix("/"), seen.insert(host.lowercased()).inserted else { return nil }
            return LocalNetworkHop(role: hop.role, host: host)
        }
    }

    /// The hop to name, only when the permission refused every host the connect could have used.
    /// A host list with one reachable server may have failed on that server for its own reason.
    internal static func blockedHop(
        among hops: [LocalNetworkHop],
        probe: any LocalNetworkAccessProbing
    ) async -> LocalNetworkHop? {
        guard let first = hops.first, !hops.contains(where: { isLoopback($0.host) }) else { return nil }
        let everyHopRefused = await withTaskGroup(of: LocalNetworkAccess.self) { group in
            for hop in hops {
                group.addTask { await probe.access(to: hop.host) }
            }
            for await access in group where access != .denied {
                group.cancelAll()
                return false
            }
            return true
        }
        return everyHopRefused ? first : nil
    }

    /// Loopback is the one destination the system never treats as local network.
    internal static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".localhost") { return true }
        if let address = IPv4Address(lowered) {
            return Array(address.rawValue).first == 127
        }
        guard let address = IPv6Address(lowered) else { return false }
        let bytes = Array(address.rawValue)
        guard bytes.count == 16 else { return false }
        if bytes == Array(repeating: 0, count: 15) + [1] { return true }
        guard bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff else { return false }
        return bytes[12] == 127
    }

    private static func directHosts(of connection: DatabaseConnection) -> [String] {
        let mode = PluginMetadataRegistry.shared.snapshot(for: connection.type)?.connectionMode ?? .network
        guard mode == .network, connection.localSocketPath == nil else { return [] }
        let listed = connection.hostListEndpoints.map(\.host)
        return listed.isEmpty ? [connection.host] : listed
    }

    private static func normalized(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }
}
