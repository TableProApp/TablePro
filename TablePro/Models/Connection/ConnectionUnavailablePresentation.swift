//
//  ConnectionUnavailablePresentation.swift
//  TablePro
//

import Foundation

/// The words a connection failure is reported in, in one place.
///
/// Two surfaces present the same reason now: the browse window's full-pane failure view, and the
/// assistant surface's inline strip, which cannot use the full view because it has to keep the
/// transcript and the pending prompt on screen underneath. A second copy of this mapping would let
/// the two drift, and the strings are exactly the part a reader compares between them.
///
/// Pure, so the mapping is testable without a window or a driver.
internal enum ConnectionUnavailablePresentation {
    internal static func headline(
        reason: ConnectionUnavailableReason,
        connectionName: String
    ) -> String {
        switch reason {
        case .notConnected, .cancelled:
            return String(format: String(localized: "Not connected to %@"), connectionName)
        case .disconnected, .disconnectedByUser:
            return String(format: String(localized: "Disconnected from %@"), connectionName)
        case .failed, .pluginMissing:
            return String(format: String(localized: "Could not connect to %@"), connectionName)
        }
    }

    internal static func detailLines(reason: ConnectionUnavailableReason) -> [String] {
        switch reason {
        case .notConnected, .cancelled, .disconnectedByUser:
            return []
        case .disconnected(let info):
            guard let info else { return [String(localized: "The connection was closed.")] }
            return lines(from: info)
        case .failed(let info), .pluginMissing(let info):
            return lines(from: info)
        }
    }

    internal static func failureInfo(reason: ConnectionUnavailableReason) -> ConnectionFailureInfo? {
        switch reason {
        case .notConnected, .cancelled, .disconnectedByUser:
            return nil
        case .disconnected(let info):
            return info
        case .failed(let info), .pluginMissing(let info):
            return info
        }
    }

    internal static func primaryActionTitle(reason: ConnectionUnavailableReason) -> String {
        switch reason {
        case .notConnected, .cancelled:
            return String(localized: "Connect")
        case .disconnected, .disconnectedByUser:
            return String(localized: "Reconnect")
        case .failed:
            return String(localized: "Try Again")
        case .pluginMissing:
            return String(localized: "Install Plugin…")
        }
    }

    internal static func lines(from info: ConnectionFailureInfo) -> [String] {
        [info.message, info.failureReason, info.recoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }
}
