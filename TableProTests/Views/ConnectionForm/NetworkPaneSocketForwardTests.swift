//
//  NetworkPaneSocketForwardTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Network pane socket forwarding")
@MainActor
struct NetworkPaneSocketForwardTests {
    @Test("An absolute socket file path raises no issue")
    func acceptsAbsoluteSocketPath() {
        #expect(NetworkPaneViewModel.socketPathIssue(for: "/var/run/postgresql/.s.PGSQL.5432") == nil)
    }

    @Test("An empty path raises no issue, because the field is optional")
    func emptyPathIsFine() {
        #expect(NetworkPaneViewModel.socketPathIssue(for: "") == nil)
        #expect(NetworkPaneViewModel.socketPathIssue(for: "   ") == nil)
    }

    @Test("A relative path is flagged")
    func flagsRelativePath() {
        #expect(NetworkPaneViewModel.socketPathIssue(for: "var/run/postgresql") == .notAbsolute)
    }

    @Test("A trailing slash is flagged, because ssh forwards to the socket file not its directory")
    func flagsDirectoryPath() {
        #expect(NetworkPaneViewModel.socketPathIssue(for: "/var/run/postgresql/") == .looksLikeDirectory)
    }

    @Test("Loading a connection populates the socket path")
    func loadsSocketPath() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let viewModel = NetworkPaneViewModel()
        viewModel.load(from: connection)

        #expect(viewModel.sshForwardUnixSocketPath == "/var/run/postgresql/.s.PGSQL.5432")
        #expect(viewModel.forwardsToUnixSocket)
    }

    @Test("Writing trims the socket path")
    func writeTrimsSocketPath() {
        let viewModel = NetworkPaneViewModel()
        viewModel.sshForwardUnixSocketPath = "  /var/run/postgresql/.s.PGSQL.5432  "

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(fields[DatabaseConnection.sshForwardUnixSocketPathKey] == "/var/run/postgresql/.s.PGSQL.5432")
    }

    @Test("Writing an empty socket path stores nothing")
    func writeOmitsEmptySocketPath() {
        let viewModel = NetworkPaneViewModel()
        viewModel.sshForwardUnixSocketPath = "   "

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(fields[DatabaseConnection.sshForwardUnixSocketPathKey] == nil)
        #expect(viewModel.forwardsToUnixSocket == false)
    }

    @Test("The socket path prompt follows the database type")
    func socketPromptFollowsType() {
        let viewModel = NetworkPaneViewModel()

        viewModel.type = .mysql
        #expect(viewModel.socketPathPrompt == "/var/run/mysqld/mysqld.sock")

        viewModel.type = .postgresql
        #expect(viewModel.socketPathPrompt == "/var/run/postgresql/.s.PGSQL.5432")
    }

    @Test("A type without a socket convention falls back to a generic prompt")
    func socketPromptFallsBackForSocketlessType() {
        let viewModel = NetworkPaneViewModel()
        viewModel.type = .clickhouse

        #expect(viewModel.socketPathPrompt == "/path/to/database.sock")
    }
}
