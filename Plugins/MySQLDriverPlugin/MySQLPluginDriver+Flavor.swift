//
//  MySQLPluginDriver+Flavor.swift
//  MySQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit

internal struct MySQLFlavorMismatchError: Error, Equatable {
    enum Kind: Equatable {
        case databendNeedsItsOwnType
        case notDatabend
        case notOceanBase
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
        case .notOceanBase:
            return String(localized: "This server did not identify as OceanBase. Check the host and port of its MySQL mode tenant.")
        }
    }
}

extension MySQLPluginDriver {
    static func initialFlavor(for config: DriverConnectionConfig) -> MySQLServerFlavor {
        switch config.additionalFields["driverVariant"] {
        case MySQLServerFlavor.databendVariant:
            return .databend
        case MySQLServerFlavor.oceanbaseVariant:
            return .oceanbase(version: nil)
        default:
            return .mysql
        }
    }

    func resolveFlavor(
        on connection: MariaDBPluginConnection,
        variant: String?,
        deadline: MySQLConnectDeadline
    ) async throws -> MySQLServerFlavor {
        let banner = connection.serverVersion()
        let bannerFlavor = MySQLServerFlavor.fromBanner(banner)

        if variant == MySQLServerFlavor.databendVariant {
            if MySQLFlavorResolution.needsDatabendProbe(banner: banner, variant: variant) {
                guard try await probeSucceeds(
                    MySQLFlavorResolution.databendProbe,
                    on: connection,
                    deadline: deadline
                ) else {
                    throw MySQLFlavorMismatchError(kind: .notDatabend)
                }
            }
            return .databend
        }

        if bannerFlavor.isDatabend {
            throw MySQLFlavorMismatchError(kind: .databendNeedsItsOwnType)
        }

        if variant == MySQLServerFlavor.oceanbaseVariant {
            let identity = try await connection.executeConnectQuery(
                MySQLFlavorResolution.oceanbaseProbe,
                deadline: deadline
            ).rows.first
            guard let flavor = MySQLFlavorResolution.oceanbaseFlavor(
                versionComment: identity?[safe: 0]?.asText,
                serverVersion: identity?[safe: 1]?.asText
            ) else {
                throw MySQLFlavorMismatchError(kind: .notOceanBase)
            }
            return flavor
        }

        guard MySQLFlavorResolution.needsTiDBVersionProbe(banner: banner, variant: variant) else {
            return bannerFlavor
        }
        guard let info = try await firstValue(
            of: MySQLFlavorResolution.tidbVersionProbe,
            on: connection,
            deadline: deadline
        ),
              let version = MySQLServerFlavor.tidbVersion(fromReleaseInfo: info) else {
            return bannerFlavor
        }
        return .tidb(version: version)
    }

    func killTarget(
        for flavor: MySQLServerFlavor,
        on connection: MariaDBPluginConnection,
        deadline: MySQLConnectDeadline
    ) async throws -> MySQLKillTarget {
        guard flavor.isTiDB || flavor.isDatabend else { return .threadId }
        let identifier = try await firstValue(
            of: MySQLFlavorResolution.connectionIdentifierProbe,
            on: connection,
            deadline: deadline
        )
        return flavor.killTarget(connectionIdentifier: identifier)
    }

    /// The read for a server that enforces check constraints without cataloguing them: TiDB from
    /// 7.2, and MariaDB 10.2.1 to 10.2.21 and 10.3.0 to 10.3.9.
    func createTableCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        let result = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
        guard let createTable = result.rows.first?[safe: 1]?.asText else { return [] }
        return MySQLCheckConstraints.parse(createTable: createTable)
    }

    private func probeSucceeds(
        _ statement: String,
        on connection: MariaDBPluginConnection,
        deadline: MySQLConnectDeadline
    ) async throws -> Bool {
        do {
            _ = try await connection.executeConnectQuery(statement, deadline: deadline)
            return true
        } catch let error as MariaDBPluginError where error.isConnectionTimeout {
            throw error
        } catch {
            return false
        }
    }

    private func firstValue(
        of statement: String,
        on connection: MariaDBPluginConnection,
        deadline: MySQLConnectDeadline
    ) async throws -> String? {
        do {
            let result = try await connection.executeConnectQuery(statement, deadline: deadline)
            return result.rows.first?.first?.asText
        } catch let error as MariaDBPluginError where error.isConnectionTimeout {
            throw error
        } catch {
            Self.logger.debug("Flavor probe failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}
