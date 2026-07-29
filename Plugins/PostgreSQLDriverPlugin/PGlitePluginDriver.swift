//
//  PGlitePluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  PGlite PluginDatabaseDriver implementation. PGlite is PostgreSQL 17 compiled to
//  WASM, reached over its socket server (@electric-sql/pglite-socket), so it reuses
//  PostgreSQLPluginDriver's introspection. It is single-connection: query cancellation
//  is a protocol no-op and a second connection is refused, so this driver suppresses
//  the wire-level cancel and drops the cancelQuery capability.
//

import Foundation
import TableProPluginKit

final class PGlitePluginDriver: PostgreSQLPluginDriver {
    private let connectHost: String
    private let connectPort: Int

    init(config: DriverConnectionConfig) {
        self.connectHost = config.host
        self.connectPort = config.port
        super.init(config: config, singleConnectionMode: true)
    }

    override var capabilities: PluginCapabilities {
        super.capabilities.subtracting(.cancelQuery)
    }

    override func connect() async throws {
        do {
            try await super.connect()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.connectError(underlying: error, host: connectHost, port: connectPort)
        }
    }

    private static func connectError(underlying: Error, host: String, port: Int) -> Error {
        let reason = (underlying as? LibPQPluginError)?.message ?? underlying.localizedDescription
        let template = String(
            localized: "Can't reach a PGlite socket server at %@:%d. Start it with 'npx @electric-sql/pglite-socket', then try again."
        )
        return PGliteConnectionError(
            pluginErrorMessage: String(format: template, host, port),
            pluginErrorDetail: reason.isEmpty ? nil : reason
        )
    }
}

struct PGliteConnectionError: PluginDriverError {
    let pluginErrorMessage: String
    let pluginErrorDetail: String?
}
