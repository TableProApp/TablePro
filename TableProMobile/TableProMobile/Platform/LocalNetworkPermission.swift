import dnssd
import Foundation
import Network
import os

enum LocalNetworkPermissionError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: """
            Local Network access is required. Open Settings > Privacy & Security > Local Network \
            and turn TablePro on. If it is already on, restart the device or update to iOS 18.6 or later.
            """)
    }
}

/// There is no API that reports Local Network permission directly. The system
/// only reveals it on a connection you actually make, so this opens a UDP
/// connection to the host the caller is about to use and reads the reason off
/// that connection's path. Connecting a UDP socket triggers the permission
/// alert without putting a packet on the wire, so the probe costs nothing the
/// caller was not already about to spend.
actor LocalNetworkPermission {
    static let shared = LocalNetworkPermission()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LocalNetworkPermission")
    private static let quietDeadline: Duration = .seconds(2)
    private static let promptDeadline: Duration = .seconds(30)
    private static let discardPort: NWEndpoint.Port = 9

    private enum Outcome: Sendable {
        case granted
        case denied
        case indeterminate
    }

    private enum Event: Sendable {
        case granted
        case denied
        case ended
        case quietDeadline
        case promptDeadline
    }

    private var inFlight: [String: Task<Outcome, Never>] = [:]

    func ensureAccess(for host: String) async throws {
        guard !Self.isLoopback(host) else { return }
        guard case .denied = await probe(host) else { return }
        throw LocalNetworkPermissionError.unavailable
    }

    /// Deliberately not cached. A UDP connection to a public host reports
    /// `.ready` without any Local Network privilege, so caching that would skip
    /// the probe for the next connection to a LAN host. Denial is not cached
    /// either, because the user can grant the permission from the alert.
    private func probe(_ host: String) async -> Outcome {
        if let existing = inFlight[host] {
            return await existing.value
        }
        let task = Task { await Self.runProbe(host: host) }
        inFlight[host] = task
        let outcome = await task.value
        inFlight[host] = nil
        return outcome
    }

    private static func runProbe(host: String) async -> Outcome {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: discardPort, using: .udp)
        let (stream, continuation) = AsyncStream<Event>.makeStream()

        connection.pathUpdateHandler = { path in
            guard path.status == .unsatisfied, path.unsatisfiedReason == .localNetworkDenied else { return }
            continuation.yield(.denied)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.yield(.granted)
            case .waiting(let error):
                if isPolicyDenied(error) || connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    continuation.yield(.denied)
                }
            case .failed, .cancelled:
                continuation.yield(.ended)
            default:
                break
            }
        }

        let deadlines = Task {
            try? await Task.sleep(for: quietDeadline)
            continuation.yield(.quietDeadline)
            try? await Task.sleep(for: promptDeadline - quietDeadline)
            continuation.yield(.promptDeadline)
        }

        connection.start(queue: .global(qos: .userInitiated))

        defer {
            deadlines.cancel()
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
            continuation.finish()
        }

        var sawDenial = false
        for await event in stream {
            switch event {
            case .granted:
                return .granted
            case .denied:
                sawDenial = true
            case .quietDeadline:
                // Nothing was reported, so this is an ordinary unreachable host
                // or a network that is down. Let the driver report its own error.
                if !sawDenial { return .indeterminate }
            case .ended, .promptDeadline:
                return sawDenial ? .denied : .indeterminate
            }
        }
        return sawDenial ? .denied : .indeterminate
    }

    /// A `.local` name fails during mDNS resolution rather than at the path, so
    /// the denial arrives as a DNS policy error instead of an unsatisfied path.
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return Int(code) == Int(kDNSServiceErr_PolicyDenied)
    }

    /// Loopback is the one destination the system never treats as local network,
    /// so it is the only case worth skipping before probing. Everything else is
    /// left to the system, which owns the definition.
    static func isLoopback(_ host: String) -> Bool {
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

    /// A hint for wording an error message, never a gate. TN3179 defines a local
    /// network by the interface it is reachable on, which an address range
    /// cannot answer, so this is right often enough to phrase a suggestion and
    /// not right enough to decide whether to ask for permission.
    static func mayBeLocalNetworkHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.hasSuffix(".local") { return true }
        if isLoopback(lowered) { return false }

        if let bytes = IPv4Address(lowered)?.rawValue, bytes.count == 4 {
            let octets = Array(bytes)
            if octets[0] == 10 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            return false
        }

        if let bytes = IPv6Address(lowered)?.rawValue, !bytes.isEmpty {
            let octets = Array(bytes)
            if (octets[0] & 0xfe) == 0xfc { return true }
            if octets.count >= 2, octets[0] == 0xfe, (octets[1] & 0xc0) == 0x80 { return true }
            return false
        }

        return false
    }
}
