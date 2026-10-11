//
//  PGliteConnectFailure.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum PGliteConnectFailure {
    private static let serverSeverityMarkers = ["FATAL:", "PANIC:", "ERROR:"]

    static func presented(_ underlying: Error, host: String, port: Int) -> Error {
        guard let failure = transportFailure(underlying) else { return underlying }
        let template = String(
            localized: "Can't reach a PGlite socket server at %@:%d. Start it with 'npx @electric-sql/pglite-socket', then try again."
        )
        return PGliteConnectionError(
            pluginErrorMessage: String(format: template, host, port),
            pluginErrorDetail: failure.message.isEmpty ? nil : failure.message
        )
    }

    private static func transportFailure(_ error: Error) -> LibPQPluginError? {
        guard let libpqError = error as? LibPQPluginError else { return nil }
        let serverAnswered = serverSeverityMarkers.contains { libpqError.message.contains($0) }
        return serverAnswered ? nil : libpqError
    }
}

struct PGliteConnectionError: PluginDriverError {
    let pluginErrorMessage: String
    let pluginErrorDetail: String?
}
