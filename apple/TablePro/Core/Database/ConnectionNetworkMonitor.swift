//
//  ConnectionNetworkMonitor.swift
//  TablePro
//

import Foundation
import Network

/// What the Network framework reports of the Mac's route out, reduced to what a reconnect acts on.
struct NetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    // A Wi-Fi rejoin or a VPN coming up keeps the path satisfied and changes these instead.
    let interfaces: [String]
}

/// Watches the default network path with `NWPathMonitor`, the reachability API Apple documents, so a session that
/// lost its connection to an outage redials once the path is back instead of at its next backoff step.
final class ConnectionNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()

    deinit {
        monitor.cancel()
    }

    /// `onChange` runs on the main actor for every update, the first one included.
    func start(onChange: @escaping @MainActor @Sendable (NetworkPathSnapshot) -> Void) {
        monitor.pathUpdateHandler = { path in
            let snapshot = NetworkPathSnapshot(
                isSatisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map(\.name)
            )
            Task { @MainActor in onChange(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "com.TablePro.connectionNetworkMonitor"))
    }
}
