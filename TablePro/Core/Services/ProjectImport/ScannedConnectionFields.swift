//
//  ScannedConnectionFields.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct ScannedConnectionFields {
    var type: DatabaseType
    var host = ""
    var port: Int?
    var database = ""
    var username = ""
    var password = ""
    var sslMode: SSLMode?
    var oracleServiceName: String?
    var redisDatabase: Int?
    var connectionName: String?
    var safeModeLevel: Int?

    init(type: DatabaseType) {
        self.type = type
    }

    func toParsedConnectionURL() -> ParsedConnectionURL {
        ParsedConnectionURL(
            type: type,
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
            sslMode: sslMode,
            authSource: nil,
            sshHost: nil,
            sshPort: nil,
            sshUsername: nil,
            sshPassword: nil,
            usePrivateKey: nil,
            useSSHAgent: nil,
            sshNoAuth: nil,
            agentSocket: nil,
            connectionName: connectionName,
            redisDatabase: redisDatabase,
            statusColor: nil,
            envTag: nil,
            schema: nil,
            tableName: nil,
            isView: false,
            filterColumn: nil,
            filterOperation: nil,
            filterValue: nil,
            filterCondition: nil,
            oracleServiceName: oracleServiceName,
            safeModeLevel: safeModeLevel,
            useSrv: false,
            mongoQueryParams: [:],
            multiHost: nil
        )
    }
}
