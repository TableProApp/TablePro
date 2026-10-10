//
//  DatabaseConnectionLocalSocketTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct DatabaseConnectionLocalSocketTests {
    private func connection(type: DatabaseType = .mysql, socket: String? = "/tmp/mysql.sock") -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Local", host: "localhost", port: 3_306, type: type)
        if let socket {
            connection.additionalFields[MySQLLocalSocket.fieldKey] = socket
        }
        return connection
    }

    @Test("MySQL and MariaDB read the stored socket")
    func mysqlFamilyReadsTheSocket() {
        #expect(connection(type: .mysql).localSocketPath == "/tmp/mysql.sock")
        #expect(connection(type: .mariadb).localSocketPath == "/tmp/mysql.sock")
    }

    @Test("A type the form offers no socket for reports none")
    func otherTypesReportNoSocket() {
        for type in [DatabaseType.tidb, .oceanbase, .databend, .postgresql] {
            #expect(connection(type: type).localSocketPath == nil, "\(type.rawValue)")
        }
    }

    @Test("Every tunnel wins over a stored socket, as it does when connecting")
    func tunnelWinsOverSocket() {
        var ssh = connection()
        ssh.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))
        #expect(ssh.localSocketPath == nil)

        var socks = connection()
        socks.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com"))
        #expect(socks.localSocketPath == nil)
    }

    @Test("The setter trims the path and removes the key when cleared")
    func setterWritesAndRemovesTheKey() {
        var connection = connection(socket: nil)
        connection.localSocketPath = "  /opt/homebrew/var/mysql/mysql.sock "
        #expect(connection.additionalFields[MySQLLocalSocket.fieldKey] == "/opt/homebrew/var/mysql/mysql.sock")

        connection.localSocketPath = "  "
        #expect(connection.additionalFields[MySQLLocalSocket.fieldKey] == nil)

        connection.localSocketPath = "/tmp/mysql.sock"
        connection.localSocketPath = nil
        #expect(connection.additionalFields[MySQLLocalSocket.fieldKey] == nil)
    }

    @Test("A connect timeout names the socket, then the host, then the connection")
    func timeoutNamesTheEndpoint() {
        #expect(connection().timeoutEndpointName == "/tmp/mysql.sock")

        var tcp = connection(socket: nil)
        tcp.host = "db.internal"
        #expect(tcp.timeoutEndpointName == "db.internal")

        tcp.host = ""
        #expect(tcp.timeoutEndpointName == "Local")
    }
}
