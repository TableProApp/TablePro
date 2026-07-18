//
//  SidebarPerfSignpost.swift
//  TablePro
//

import Foundation
import os

internal enum SidebarPerfSignpost {
    private static let subsystem = "com.TablePro"

    internal static let signposter = OSSignposter(subsystem: subsystem, category: "SidebarPerf")
    internal static let logger = Logger(subsystem: subsystem, category: "SidebarPerf")

    internal static func recordBodyEvaluation(_ view: StaticString, connectionId: UUID) {
        signposter.emitEvent(view, "connection=\(connectionId.uuidString, privacy: .public)")
        logger.debug("body \(String(describing: view), privacy: .public) connection=\(connectionId.uuidString, privacy: .public)")
    }

    internal static func recordEvent(_ name: StaticString, connectionId: UUID) {
        signposter.emitEvent(name, "connection=\(connectionId.uuidString, privacy: .public)")
        logger.debug("event \(String(describing: name), privacy: .public) connection=\(connectionId.uuidString, privacy: .public)")
    }

    internal static func beginInterval(
        _ name: StaticString,
        connectionId: UUID
    ) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID(), "connection=\(connectionId.uuidString, privacy: .public)")
    }

    internal static func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
