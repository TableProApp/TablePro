//
//  LocalNetworkAccessProbe.swift
//  TablePro
//

import dnssd
import Foundation
import Network

internal enum LocalNetworkAccess: Equatable, Sendable {
    case denied
    case granted
    case undetermined
}

internal protocol LocalNetworkAccessProbing: Sendable {
    func access(to host: String) async -> LocalNetworkAccess
}

/// What a probe connection reported, reduced to whether the Local Network permission refused it.
internal enum LocalNetworkProbeSignal: Sendable {
    case path(status: NWPath.Status, reason: NWPath.UnsatisfiedReason)
    case ready
    case waiting(NWError, status: NWPath.Status?, reason: NWPath.UnsatisfiedReason?)
    case ended
    case deadline

    /// Nil while the probe should keep listening.
    internal var verdict: LocalNetworkAccess? {
        switch self {
        case .path(let status, let reason):
            return Self.isDenied(status: status, reason: reason) ? .denied : nil
        case .ready:
            return .granted
        case .waiting(let error, let status, let reason):
            if Self.isPolicyDenied(error) { return .denied }
            if let status, let reason, Self.isDenied(status: status, reason: reason) { return .denied }
            return .undetermined
        case .ended, .deadline:
            return .undetermined
        }
    }

    // A satisfied path still reports `.notAvailable` as its reason, so the reason only counts on an unsatisfied one.
    private static func isDenied(status: NWPath.Status, reason: NWPath.UnsatisfiedReason) -> Bool {
        status == .unsatisfied && reason == .localNetworkDenied
    }

    // A `.local` name is refused during mDNS resolution, before there is a path to read.
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return Int(code) == Int(kDNSServiceErr_PolicyDenied)
    }
}

/// No API reports the Local Network permission. The system answers on a connection, so this opens a
/// UDP connection to the host and reads the answer off its path. Connecting a UDP socket sends nothing.
internal struct NetworkFrameworkLocalNetworkProbe: LocalNetworkAccessProbing {
    private static let discardPort: NWEndpoint.Port = 9
    private static let queue = DispatchQueue(label: "com.TablePro.LocalNetworkAccessProbe", qos: .userInitiated)

    private let deadline: Duration

    internal init(deadline: Duration = .seconds(2)) {
        self.deadline = deadline
    }

    internal func access(to host: String) async -> LocalNetworkAccess {
        // The permission arrived in macOS 15, so nothing earlier refuses a local address.
        guard #available(macOS 15, *) else { return .granted }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: Self.discardPort, using: .udp)
        let (signals, continuation) = AsyncStream<LocalNetworkProbeSignal>.makeStream()

        connection.pathUpdateHandler = { path in
            continuation.yield(.path(status: path.status, reason: path.unsatisfiedReason))
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.yield(.ready)
            case .waiting(let error):
                let path = connection.currentPath
                continuation.yield(.waiting(error, status: path?.status, reason: path?.unsatisfiedReason))
            case .failed, .cancelled:
                continuation.yield(.ended)
            default:
                break
            }
        }

        let deadline = deadline
        let timer = Task {
            try? await Task.sleep(for: deadline)
            continuation.yield(.deadline)
        }
        connection.start(queue: Self.queue)

        defer {
            timer.cancel()
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
            continuation.finish()
        }

        for await signal in signals {
            if let verdict = signal.verdict { return verdict }
        }
        return .undetermined
    }
}
