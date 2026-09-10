//
//  ConnectionStageLabelFormatterTests.swift
//  TableProTests
//
//  The HIG makes the description beside a progress indicator conditional: "If it's helpful,
//  display a description that provides additional context for the task. Be accurate and succinct.
//  Avoid vague terms like loading or authenticating because they seldom add value."
//
//  The previous version of this suite claimed to hold that line and did not. It compared the whole
//  label against a list of banned words with `banned.contains(label)`, so "Authenticating postgres"
//  passed while being exactly the word the HIG names, and the file's own doc comment asserted a
//  rule the code had stopped keeping.
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

    /// The steps the card stays quiet about. Each one restates the name and endpoint already above
    /// it, and two of them are reported by a handful of the 38 drivers, so the same connect read
    /// differently depending on which plugin answered.
    private static let silentStages: [ConnectionStage] = [
        .openingConnection,
        .negotiatingEncryption,
        .authenticating,
        .preparingSession
    ]

    @Test("A step that only restates the card draws nothing")
    func genericStepsDrawNothing() {
        let connection = Self.connection()

        for stage in Self.silentStages {
            #expect(
                ConnectionStageLabelFormatter.description(for: stage, connection: connection) == nil,
                "\(stage) has nothing to add to the name and endpoint above it"
            )
        }
    }

    /// The rule the old suite meant to enforce, written so that a label merely containing the word
    /// fails rather than only a label equal to it.
    @Test("No drawn description uses a bare status verb")
    func drawnDescriptionsAvoidVagueVerbs() {
        let connection = Self.connection()
        let vague = ["loading", "authenticating", "connecting", "please wait", "negotiating"]

        for stage in Self.stages {
            guard let description = ConnectionStageLabelFormatter
                .description(for: stage, connection: connection)?.lowercased() else { continue }
            for word in vague {
                #expect(!description.contains(word), "\(stage) drew \"\(description)\"")
            }
        }
    }

    /// The three that survive are the ones where the app is blocked on something outside itself.
    @Test("A step the reader can act on names what the app is waiting for")
    func actionableStepsNameTheWait() {
        let connection = Self.connection()

        for stage in [ConnectionStage.runningPreConnectScript, .awaitingCredentials] {
            let description = ConnectionStageLabelFormatter.description(for: stage, connection: connection)
            #expect(description?.isEmpty == false)
        }
    }

    @Test("A tunnel step names the host it is waiting for")
    func tunnelStepNamesTheJumpHost() {
        var sshConfig = SSHConfiguration()
        sshConfig.enabled = true
        sshConfig.host = "bastion.example.com"
        sshConfig.username = "deploy"

        var connection = Self.connection()
        connection.sshTunnelMode = .inline(sshConfig)

        let description = ConnectionStageLabelFormatter.description(
            for: .resolvingTunnel,
            connection: connection
        )

        #expect(description?.contains("bastion.example.com") == true)
    }

    /// A tunnel with nothing to name still says which of the two ends is holding things up.
    @Test("A tunnel with no host still draws")
    func tunnelWithoutAHostStillDraws() {
        let description = ConnectionStageLabelFormatter.description(
            for: .resolvingTunnel,
            connection: Self.connection()
        )

        #expect(description?.isEmpty == false)
    }

    @Test("A plugin's own wording is passed through untouched")
    func customStagePassesThrough() {
        let description = ConnectionStageLabelFormatter.description(
            for: .custom("Discovering replica set members"),
            connection: Self.connection()
        )

        #expect(description == "Discovering replica set members")
    }

    /// A progress bar tells VoiceOver nothing, so the steps the card stays quiet about are still
    /// spoken. Quiet on screen is not quiet in the accessibility tree.
    @Test("Every stage is spoken, including the ones that draw nothing")
    func everyStageIsSpoken() {
        let connection = Self.connection(name: "Prod DB")

        for stage in Self.stages {
            let announcement = ConnectionStageLabelFormatter.announcement(for: stage, connection: connection)
            #expect(announcement.contains("Prod DB"))
            #expect(announcement.count > "Prod DB".count)
        }
    }

    @Test("The spoken form of authenticating names the user it is authenticating")
    func spokenAuthenticationNamesTheUser() {
        let announcement = ConnectionStageLabelFormatter.announcement(
            for: .authenticating,
            connection: Self.connection(username: "reporting_ro")
        )

        #expect(announcement.contains("reporting_ro"))
    }

    @Test("A connection with no username is still spoken")
    func spokenAuthenticationWithoutUsername() {
        let announcement = ConnectionStageLabelFormatter.announcement(
            for: .authenticating,
            connection: Self.connection(username: "  ")
        )

        #expect(!announcement.isEmpty)
        #expect(!announcement.contains("  "))
    }
}
