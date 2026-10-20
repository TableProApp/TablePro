//
//  DatabaseManager+LocalNetwork.swift
//  TablePro
//

import Foundation
import os
import TableProSSHConfig

extension DatabaseManager {
    /// macOS 15 refuses a socket to a local-network host when TablePro lacks the Local Network
    /// permission, and the driver reports it as an unreachable host. Probing the hop it dialed tells
    /// the two apart.
    internal func diagnosedConnectFailure(_ error: Error, for connection: DatabaseConnection) async -> Error {
        guard !Task.isCancelled, LocalNetworkAccessDiagnosis.canExplain(error, fields: connection.additionalFields) else {
            return error
        }
        let dialed = SSHProfileStorage.shared.refreshingLinkedProfile(connection)
        let hops = LocalNetworkAccessDiagnosis.hops(
            for: dialed,
            sshDocument: await SSHConfigCache.shared.current()
        )
        guard let hop = await LocalNetworkAccessDiagnosis.blockedHop(among: hops, probe: localNetworkProbe) else {
            return error
        }
        Self.logger.notice("Local Network access is off, a connect to \(hop.host, privacy: .private) was refused")
        return LocalNetworkAccessError(hop: hop, underlying: error)
    }
}
