//
//  ConnectionStageLabelFormatterTests.swift
//  TableProTests
//
//  The HIG names "loading" and "authenticating" as descriptions that add nothing. A step label
//  has to say what it is acting on, and the spoken form has to name the connection because it
//  is heard without the window around it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection stage labels")
struct ConnectionStageLabelFormatterTests {
    private static func connection(
        name: String = "Prod DB",
        username: String = "postgres"
    ) -> DatabaseConnection {
        DatabaseConnection(
            name: name,
            host: "db.internal",
            port: 5_432,
            username: username,
            type: .postgresql
        )
    }

    private static let stages: [ConnectionStage] = [
        .resolvingTunnel,
        .runningPreConnectScript,
        .awaitingCredentials,
        .openingConnection,
        .negotiatingEncryption,
        .authenticating,
        .preparingSession
    ]

    @Test("No step is a bare verb")
    func noStepIsABareVerb() {
        let connection = Self.connection()
        let banned = ["Loading", "Authenticating", "Connecting", "Please wait"]

        for stage in Self.stages {
            let label = ConnectionStageLabelFormatter.stepLabel(for: stage, connection: connection)
            #expect(!label.isEmpty)
            #expect(!banned.contains(label))
        }
    }

    @Test("Authenticating names the user it is authenticating")
    func authenticatingNamesTheUser() {
        let label = ConnectionStageLabelFormatter.stepLabel(
            for: .authenticating,
            connection: Self.connection(username: "reporting_ro")
        )

        #expect(label.contains("reporting_ro"))
    }

    @Test("A connection with no username still gets a usable step")
    func authenticatingWithoutUsername() {
        let label = ConnectionStageLabelFormatter.stepLabel(
            for: .authenticating,
            connection: Self.connection(username: "  ")
        )

        #expect(!label.isEmpty)
        #expect(!label.contains("  "))
    }

    @Test("Every spoken stage names the connection")
    func announcementsNameTheConnection() {
        let connection = Self.connection(name: "Prod DB")

        for stage in Self.stages {
            let announcement = ConnectionStageLabelFormatter.announcement(for: stage, connection: connection)
            #expect(announcement.contains("Prod DB"))
        }
    }

    @Test("A plugin's own wording is passed through untouched")
    func customStagePassesThrough() {
        let label = ConnectionStageLabelFormatter.stepLabel(
            for: .custom("Discovering replica set members"),
            connection: Self.connection()
        )

        #expect(label == "Discovering replica set members")
    }

    @Test("An SSH tunnel step names the host it goes through")
    func tunnelStepNamesTheJumpHost() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "bastion.example.com"
        sshConfig.username = "deploy"

        var connection = Self.connection()
        connection.sshTunnelMode = .inline(sshConfig)

        let label = ConnectionStageLabelFormatter.stepLabel(for: .resolvingTunnel, connection: connection)

        #expect(label.contains("bastion.example.com"))
    }
}
