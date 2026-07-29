//
//  ParsedConnectionURL+Scanned.swift
//  TablePro
//

import Foundation

extension ParsedConnectionURL {
    func with(
        username overriddenUsername: String? = nil,
        password overriddenPassword: String? = nil,
        safeModeLevel overriddenSafeModeLevel: Int? = nil
    ) -> ParsedConnectionURL {
        ParsedConnectionURL(
            type: type,
            host: host,
            port: port,
            database: database,
            username: overriddenUsername ?? username,
            password: overriddenPassword ?? password,
            sslMode: sslMode,
            authSource: authSource,
            sshHost: sshHost,
            sshPort: sshPort,
            sshUsername: sshUsername,
            sshPassword: sshPassword,
            usePrivateKey: usePrivateKey,
            useSSHAgent: useSSHAgent,
            sshNoAuth: sshNoAuth,
            agentSocket: agentSocket,
            connectionName: connectionName,
            redisDatabase: redisDatabase,
            statusColor: statusColor,
            envTag: envTag,
            schema: schema,
            tableName: tableName,
            isView: isView,
            filterColumn: filterColumn,
            filterOperation: filterOperation,
            filterValue: filterValue,
            filterCondition: filterCondition,
            oracleServiceName: oracleServiceName,
            safeModeLevel: overriddenSafeModeLevel ?? safeModeLevel,
            useSrv: useSrv,
            mongoQueryParams: mongoQueryParams,
            multiHost: multiHost
        )
    }
}
