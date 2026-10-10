//
//  ConnectionImportLinkSocketTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionImportLinkSocketTests {
    private func importLink(_ items: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "name", value: "Local")] + items
        return try #require(components.url)
    }

    private func imported(_ items: [URLQueryItem]) throws -> ExportableConnection {
        guard case .success(.importConnection(let parsed)) = DeeplinkParser.parse(try importLink(items)) else {
            throw DeeplinkError.malformedPath("not an import")
        }
        return parsed
    }

    private func savedConnection(from exportable: ExportableConnection) -> DatabaseConnection {
        ConnectionExportService.buildDatabaseConnection(
            id: UUID(), from: exportable, name: exportable.name, tagIdsByName: [:], groupIdsByName: [:]
        )
    }

    @Test("A link with a socket and no host imports a localhost socket connection")
    func socketWithoutHost() throws {
        let path = "/Users/me/Library/Application Support/Local/run/ab12/mysql/mysqld.sock"
        let exportable = try imported([
            URLQueryItem(name: "type", value: "MySQL"),
            URLQueryItem(name: "socket", value: path),
            URLQueryItem(name: "username", value: "root"),
            URLQueryItem(name: "database", value: "local")
        ])

        #expect(exportable.host == "localhost")
        let connection = savedConnection(from: exportable)
        #expect(connection.localSocketPath == path)
        #expect(connection.database == "local")
    }

    @Test("af_localSocketPath is read like socket")
    func genericFieldStillWorks() throws {
        let exportable = try imported([
            URLQueryItem(name: "type", value: "MariaDB"),
            URLQueryItem(name: "host", value: "localhost"),
            URLQueryItem(name: "af_localSocketPath", value: "/tmp/mysql.sock")
        ])
        #expect(savedConnection(from: exportable).localSocketPath == "/tmp/mysql.sock")
    }

    @Test(
        "A path that cannot be a socket refuses the link",
        arguments: ["mysql.sock", "~/mysql.sock", "/" + String(repeating: "a", count: 103), "/tmp/prod.sock\u{0}/../dev.sock"]
    )
    func invalidSocketRefused(_ path: String) throws {
        for name in ["socket", "af_localSocketPath"] {
            let url = try importLink([
                URLQueryItem(name: "type", value: "MySQL"),
                URLQueryItem(name: name, value: path)
            ])
            guard case .failure(let error) = DeeplinkParser.parse(url) else {
                Issue.record("Expected \(name)=\(path) to be refused"); continue
            }
            #expect(error == .invalidParameter("socket"))
        }
    }

    @Test("An engine without a socket mode drops the socket and still needs a host")
    func otherEngineDropsSocket() throws {
        let url = try importLink([
            URLQueryItem(name: "type", value: "PostgreSQL"),
            URLQueryItem(name: "socket", value: "/tmp/.s.PGSQL.5432")
        ])
        guard case .failure(let error) = DeeplinkParser.parse(url) else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .missingRequiredParam("host"))

        let withHost = try imported([
            URLQueryItem(name: "type", value: "PostgreSQL"),
            URLQueryItem(name: "host", value: "db.example.com"),
            URLQueryItem(name: "af_localSocketPath", value: "/tmp/mysql.sock")
        ])
        #expect(withHost.additionalFields?[MySQLLocalSocket.fieldKey] == nil)
    }

    @Test("A link through an SSH tunnel drops the socket, the tunnel decides")
    func sshDropsSocket() throws {
        let exportable = try imported([
            URLQueryItem(name: "type", value: "MySQL"),
            URLQueryItem(name: "host", value: "127.0.0.1"),
            URLQueryItem(name: "socket", value: "/tmp/mysql.sock"),
            URLQueryItem(name: "ssh", value: "1"),
            URLQueryItem(name: "sshHost", value: "bastion.example.com")
        ])
        #expect(exportable.additionalFields?[MySQLLocalSocket.fieldKey] == nil)
    }

    @Test("A link with neither host nor socket still asks for host")
    func missingHost() throws {
        let url = try importLink([URLQueryItem(name: "type", value: "MySQL")])
        guard case .failure(let error) = DeeplinkParser.parse(url) else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .missingRequiredParam("host"))
    }

    @Test("Copy TablePro Link writes socket= in place of host and port, and reads back")
    func builderRoundTrip() throws {
        let path = "/Users/me/Library/Application Support/Local/run/ab12/mysql/a+b.sock"
        var original = DatabaseConnection(
            name: "Local", host: "db.internal", port: 3_307, database: "local", username: "root", type: .mysql
        )
        original.localSocketPath = path

        let link = try #require(ConnectionExportService.buildImportDeeplink(for: original))
        let items = URLComponents(string: link)?.queryItems ?? []
        #expect(items.first { $0.name == "socket" }?.value == path)
        #expect(!items.contains { $0.name == "host" || $0.name == "port" || $0.name == "af_localSocketPath" })

        let url = try #require(URL(string: link))
        guard case .success(.importConnection(let parsed)) = DeeplinkParser.parse(url) else {
            Issue.record("Failed to parse \(link)"); return
        }
        #expect(savedConnection(from: parsed).localSocketPath == path)
    }

    @Test("A TCP connection's link has no socket")
    func builderWithoutSocket() throws {
        var tunnelled = DatabaseConnection(
            name: "Tunnel", host: "127.0.0.1", port: 3_306, database: "db", username: "root", type: .mysql
        )
        tunnelled.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        tunnelled.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))

        let link = try #require(ConnectionExportService.buildImportDeeplink(for: tunnelled))
        let names = Set((URLComponents(string: link)?.queryItems ?? []).map(\.name))
        #expect(names.contains("host"))
        #expect(!names.contains("socket"))
        #expect(!names.contains("af_localSocketPath"))
    }
}
