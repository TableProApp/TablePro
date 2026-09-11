//
//  MySQLPluginDriver+Flavor.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal struct MySQLFlavorMismatchError: Error, Equatable {
    enum Kind: Equatable {
        case databendNeedsItsOwnType
        case notDatabend
    }

    let kind: Kind
}

extension MySQLFlavorMismatchError: PluginDriverError {
    var pluginErrorMessage: String {
        switch kind {
        case .databendNeedsItsOwnType:
            return String(localized: "This server is Databend. Edit the connection and choose Databend as its type.")
        case .notDatabend:
            return String(localized: "This server did not identify as Databend. Check the host and port of its MySQL handler.")
        }
    }
}

extension MySQLPluginDriver {
    static func initialFlavor(for config: DriverConnectionConfig) -> MySQLServerFlavor {
        config.additionalFields["driverVariant"] == MySQLServerFlavor.databendVariant ? .databend : .mysql
    }

    func resolveFlavor(on connection: MariaDBPluginConnection, variant: String?) async throws -> MySQLServerFlavor {
        let banner = connection.serverVersion()
        let bannerFlavor = MySQLServerFlavor.fromBanner(banner)

        if variant == MySQLServerFlavor.databendVariant {
            if MySQLFlavorResolution.needsDatabendProbe(banner: banner, variant: variant) {
                guard await probeSucceeds(MySQLFlavorResolution.databendProbe, on: connection) else {
                    throw MySQLFlavorMismatchError(kind: .notDatabend)
                }
            }
            return .databend
        }

        if bannerFlavor.isDatabend {
            throw MySQLFlavorMismatchError(kind: .databendNeedsItsOwnType)
        }

        guard MySQLFlavorResolution.needsTiDBVersionProbe(banner: banner, variant: variant) else {
            return bannerFlavor
        }
        guard let info = await firstValue(of: MySQLFlavorResolution.tidbVersionProbe, on: connection),
              let version = MySQLServerFlavor.tidbVersion(fromReleaseInfo: info) else {
            return bannerFlavor
        }
        return .tidb(version: version)
    }

    func killTarget(for flavor: MySQLServerFlavor, on connection: MariaDBPluginConnection) async -> MySQLKillTarget {
        guard flavor.isTiDB || flavor.isDatabend else { return .threadId }
        let identifier = await firstValue(of: MySQLFlavorResolution.connectionIdentifierProbe, on: connection)
        return flavor.killTarget(connectionIdentifier: identifier)
    }

    func tidbCheckConstraints(table: String) async throws -> [PluginCheckConstraintInfo] {
        let result = try await execute(query: "SHOW CREATE TABLE \(quoteIdentifier(table))")
        guard let createTable = result.rows.first?[safe: 1]?.asText else { return [] }
        return TiDBCheckConstraints.parse(createTable: createTable)
    }

    private func probeSucceeds(_ statement: String, on connection: MariaDBPluginConnection) async -> Bool {
        do {
            _ = try await connection.executeQuery(statement)
            return true
        } catch {
            return false
        }
    }

    private func firstValue(of statement: String, on connection: MariaDBPluginConnection) async -> String? {
        do {
            let result = try await connection.executeQuery(statement)
            return result.rows.first?.first?.asText
        } catch {
            Self.logger.debug("Flavor probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
