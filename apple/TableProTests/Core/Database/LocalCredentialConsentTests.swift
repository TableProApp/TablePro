//
//  LocalCredentialConsentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
@testable import TableProSSHConfig
import Testing

@MainActor
private final class SignInQuestionSpy {
    var answer: ConsentAnswer
    private(set) var questions: [LocalCredentialQuestion] = []

    init(answer: ConsentAnswer) {
        self.answer = answer
    }

    func ask(_ question: LocalCredentialQuestion) async -> ConsentAnswer {
        questions.append(question)
        return answer
    }
}

private actor ReadCounter {
    private var count = 0

    func next() -> Int {
        defer { count += 1 }
        return count
    }
}

@MainActor
struct LocalCredentialConsentTests {
    private let suite: EphemeralDefaults
    private let store: ConnectionApprovalStore
    private let spy: SignInQuestionSpy

    init() throws {
        suite = try EphemeralDefaults()
        store = ConnectionApprovalStore(kind: .localCredentials, defaults: suite.defaults, savedConnections: { [] })
        spy = SignInQuestionSpy(answer: .declined)
    }

    // `sshConfig` stands in for `~/.ssh/config`, so no test reads this Mac's own.
    private func makeConsent(sshConfig: String = "") -> LocalCredentialConsent {
        LocalCredentialConsent(
            approvals: store,
            ask: { [spy] question in await spy.ask(question) },
            sshDocument: { SSHConfigParser.parseDocumentContent(sshConfig) }
        )
    }

    // An imported file whose author picked the server and asked for this Mac's Kerberos ticket.
    private func importedWindowsSignIn() -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Reports",
            host: "sql.attacker.example",
            port: 1_433,
            type: .mssql,
            additionalFields: ["mssqlAuthMethod": "windows"]
        )
        connection.origin = .imported
        return connection
    }

    @Test("An imported row that signs in with this Mac's Kerberos ticket asks before it connects")
    func importedWindowsSignInAsks() async throws {
        spy.answer = .approved
        let connection = importedWindowsSignIn()
        #expect(makeConsent().requiresApproval(connection))

        try await makeConsent().check(connection, trigger: .request)

        let question = try #require(spy.questions.first)
        #expect(spy.questions.count == 1)
        #expect(question.connectionName == "Reports")
        #expect(question.uses == ["Authentication: Windows Authentication (Kerberos)"])
        #expect(question.destination == "sql.attacker.example:1433")
        #expect(question.origin == .imported)
    }

    @Test("After a yes the next connect does not ask, in the background too")
    func approvalIsKept() async throws {
        spy.answer = .approved
        let connection = importedWindowsSignIn()

        try await makeConsent().check(connection, trigger: .request)
        try await makeConsent().check(connection, trigger: .background)
        try await makeConsent().check(connection, trigger: .request)

        #expect(spy.questions.count == 1)
        #expect(!makeConsent().requiresApproval(connection))
    }

    @Test("A changed host asks again")
    func hostChangeAsksAgain() async throws {
        spy.answer = .approved
        var connection = importedWindowsSignIn()
        connection.host = "sql.corp.example"
        store.approve(connection)
        connection.host = "sql.attacker.example"
        let moved = connection

        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            try await makeConsent().check(moved, trigger: .background)
        }
        try await makeConsent().check(moved, trigger: .request)

        #expect(spy.questions.map { $0.destination } == ["sql.attacker.example:1433"])
    }

    @Test("A connect TablePro starts on its own is refused without a prompt")
    func backgroundIsRefused() async {
        spy.answer = .approved
        let connection = importedWindowsSignIn()

        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            try await makeConsent().check(connection, trigger: .background)
        }

        #expect(spy.questions.isEmpty)
        #expect(!store.isApproved(connection))
    }

    @Test("A declined prompt approves nothing and reads as the person cancelling")
    func declineIsACancel() async {
        let connection = importedWindowsSignIn()

        await #expect(throws: LocalCredentialConsentError.declined) {
            try await makeConsent().check(connection, trigger: .request)
        }

        #expect(!store.isApproved(connection))
        #expect(ConnectionFailureClassifier.isUserCancelled(LocalCredentialConsentError.declined))
        #expect(ConnectionFailureClassifier.outcome(for: LocalCredentialConsentError.declined) == .cancelled)
        #expect(!ConnectionFailureClassifier.isUserCancelled(LocalCredentialConsentError.needsPerson))
    }

    @Test("An unanswered prompt is a refusal of its own")
    func unansweredIsRefused() async {
        spy.answer = .unanswered
        let connection = importedWindowsSignIn()

        await #expect(throws: LocalCredentialConsentError.unanswered) {
            try await makeConsent().check(connection, trigger: .request)
        }
        #expect(!store.isApproved(connection))
    }

    private func bridgeAsking(about connection: DatabaseConnection) throws -> (DatabaseAccessBridge, () -> Void) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-signin-bridge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("connections.json")
        let storageSuite = try EphemeralDefaults()
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: storageSuite.defaults, keychain: InMemoryKeychain())
        storage.addConnection(connection)
        let manager = DatabaseManager(connectionStorage: storage, localCredentialConsent: makeConsent())
        return (DatabaseAccessBridge(manager: manager), {
            manager.removeSession(for: connection.id)
            storageSuite.defaults.removePersistentDomain(forName: storageSuite.suiteName)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        })
    }

    @Test("MCP, the assistant and AppleScript get a declined sign-in prompt as a refusal")
    func bridgeReportsDeclinedAsForbidden() async throws {
        let connection = importedWindowsSignIn()
        let (bridge, cleanUp) = try bridgeAsking(about: connection)
        defer { cleanUp() }

        do {
            _ = try await bridge.connect(connectionId: connection.id)
            Issue.record("The connect went ahead without consent")
        } catch DatabaseAccessError.forbidden {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(spy.questions.count == 1)
        #expect(!store.isApproved(connection))
    }

    @Test("A bridge tool call that needs a session reports an unanswered sign-in prompt as a timeout")
    func bridgeReportsUnansweredAsTimeout() async throws {
        spy.answer = .unanswered
        let connection = importedWindowsSignIn()
        let (bridge, cleanUp) = try bridgeAsking(about: connection)
        defer { cleanUp() }

        do {
            try await bridge.ensureConnected(connection.id)
            Issue.record("The connect went ahead without consent")
        } catch DatabaseAccessError.timeout {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(spy.questions.count == 1)
    }

    @Test("A gesture that asked first is not asked again at the connect")
    func gestureAsksOnce() async throws {
        spy.answer = .approved
        let consent = makeConsent()
        let connection = importedWindowsSignIn()

        #expect(await consent.confirm(connection))
        try await consent.check(connection, trigger: .request)

        #expect(spy.questions.count == 1)
    }

    @Test("A declined gesture leaves nothing approved")
    func declinedGestureApprovesNothing() async {
        let consent = makeConsent()
        let connection = importedWindowsSignIn()

        #expect(await consent.confirm(connection) == false)
        #expect(consent.requiresApproval(connection))
    }

    @Test("A row that signs in with its own access key never asks")
    func accessKeyNeverAsks() async throws {
        var connection = DatabaseConnection(
            name: "Orders",
            host: "orders.abc123.us-east-1.rds.amazonaws.com",
            port: 5_432,
            type: .postgresql,
            additionalFields: ["awsAuth": "accessKey", "awsRegion": "us-east-1", "awsAccessKeyId": "AKIAEXAMPLE"]
        )
        connection.origin = .imported

        try await makeConsent().check(connection, trigger: .background)

        #expect(!makeConsent().requiresApproval(connection))
        #expect(spy.questions.isEmpty)
    }

    @Test("A row with no local sign-in connects as it is, in the background too")
    func plainRowNeverAsks() async throws {
        var connection = DatabaseConnection(name: "Plain", host: "db.example.com", username: "app", type: .postgresql)
        connection.origin = .imported

        try await makeConsent().check(connection, trigger: .background)

        #expect(spy.questions.isEmpty)
    }

    @Test("A duplicate carries its source's approval")
    func duplicateCarriesTheApproval() async throws {
        let source = importedWindowsSignIn()
        store.approve(source)
        var duplicate = importedWindowsSignIn()
        duplicate.name = "Reports (Copy)"

        store.copyApprovals(from: source.id, to: duplicate.id)

        try await makeConsent().check(duplicate, trigger: .background)
        #expect(spy.questions.isEmpty)
    }

    @Test("Deleting the connection revokes its approval")
    func deleteRevokes() async {
        let connection = importedWindowsSignIn()
        store.approve(connection)

        store.revoke(for: connection.id)

        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            try await makeConsent().check(connection, trigger: .background)
        }
    }

    @Test("The first use approves this Mac's own sign-in and leaves an imported one to ask")
    func migrationApprovesOnlyThisMacRows() async throws {
        var own = importedWindowsSignIn()
        own.host = "sql.corp.example"
        own.origin = .thisMac
        let imported = importedWindowsSignIn()
        let migrating = ConnectionApprovalStore(
            kind: .localCredentials,
            defaults: suite.defaults,
            savedConnections: { [own, imported] }
        )
        let consent = LocalCredentialConsent(approvals: migrating, ask: { [spy] question in await spy.ask(question) })

        try await consent.check(own, trigger: .background)
        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            try await consent.check(imported, trigger: .background)
        }
    }

    @Test("The BigQuery question names the project Application Default Credentials would act in")
    func applicationDefaultCredentialsNameTheProject() {
        var connection = DatabaseConnection(
            name: "Warehouse",
            host: "",
            type: .bigQuery,
            additionalFields: ["bqAuthMethod": "adc", "bqProjectId": "attacker-project"]
        )
        connection.origin = .imported

        let question = LocalCredentialConsent.question(for: connection)

        #expect(question.uses == ["Auth Method: Application Default Credentials"])
        #expect(question.destination.contains("attacker-project"))
        #expect(LocalCredentialPrompt.message(for: question).contains("attacker-project"))
    }

    @Test("The question names the RDS endpoint an IAM token is signed for")
    func rdsEndpointIsNamed() {
        var connection = DatabaseConnection(
            name: "Orders",
            host: "127.0.0.1",
            port: 5_432,
            type: .postgresql,
            additionalFields: [
                "awsAuth": "profile",
                "awsProfileName": "prod",
                "awsRDSEndpoint": "orders.abc123.us-east-1.rds.amazonaws.com:5432"
            ]
        )
        connection.origin = .imported

        let destination = LocalCredentialConsent.question(for: connection).destination

        #expect(destination.hasPrefix("127.0.0.1:5432"))
        #expect(destination.contains("orders.abc123.us-east-1.rds.amazonaws.com:5432"))
    }

    @Test("An endpoint the chosen sign-in ignores is not named")
    func hiddenEndpointIsNotNamed() {
        let connection = DatabaseConnection(
            name: "Orders",
            host: "db.example.com",
            port: 5_432,
            type: .postgresql,
            additionalFields: ["awsAuth": "off", "awsRDSEndpoint": "decoy.rds.amazonaws.com"]
        )

        #expect(!connection.destinationSummary.contains("decoy"))
    }

    @Test("A toggle reads as its label, and a field the plugin does not declare as its id and value")
    func usesReadInTheFormsWords() {
        let toggle = LocalCredentialConsent.describe(
            LocalCredentialUse(fieldId: "usePgpass", value: "true"),
            fields: [ConnectionField(id: "usePgpass", label: "Use ~/.pgpass", fieldType: .toggle)]
        )
        let undeclared = LocalCredentialConsent.describe(
            LocalCredentialUse(fieldId: "mongoParam_authMechanism", value: "MONGODB-AWS"),
            fields: []
        )

        #expect(toggle == "Use ~/.pgpass")
        #expect(undeclared == "authMechanism: MONGODB-AWS")
    }

    @Test("A MongoDB row that signs in with this Mac's AWS environment asks")
    func mongoAWSAsks() async {
        var connection = DatabaseConnection(
            name: "Documents",
            host: "mongo.attacker.example",
            port: 27_017,
            type: .mongodb,
            additionalFields: ["mongoAuthMechanism": "MONGODB-AWS"]
        )
        connection.origin = .link

        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            try await makeConsent().check(connection, trigger: .background)
        }
    }

    @Test("The prompt names the server, the sign-in and where the row came from, each on its own lines")
    func promptMessage() {
        var connection = importedWindowsSignIn()
        connection.name = "Reports\n\nTablePro verified this server."

        let message = LocalCredentialPrompt.message(for: LocalCredentialConsent.question(for: connection))

        #expect(message.contains("sql.attacker.example"))
        #expect(message.contains("Windows Authentication (Kerberos)"))
        #expect(message.contains("imported"))
        #expect(!message.contains("Reports\n"))
    }

    @Test("A background reconnect stops at the sign-in question before any variable is read")
    func connectChecksTheSignInFirst() async throws {
        let envSuite = try EphemeralDefaults()
        let envVarConsent = EnvVarReferenceConsent(
            approvals: ConnectionApprovalStore(
                kind: .envVarReferences,
                defaults: envSuite.defaults,
                savedConnections: { [] }
            ),
            isFeatureAvailable: { true },
            ask: { _ in .approved }
        )
        let signInSuite = try EphemeralDefaults()
        let signInConsent = LocalCredentialConsent(
            approvals: ConnectionApprovalStore(
                kind: .localCredentials,
                defaults: signInSuite.defaults,
                savedConnections: { [] }
            ),
            ask: { _ in .approved }
        )
        let manager = DatabaseManager(envVarReferenceConsent: envVarConsent, localCredentialConsent: signInConsent)
        var connection = importedWindowsSignIn()
        connection.username = "$PROD_DB_USER"

        await #expect(throws: LocalCredentialConsentError.needsPerson) {
            try await manager.connectToSession(connection, trigger: .background)
        }
        #expect(manager.activeSessions[connection.id] == nil)
    }

    // A teammate's copy of a connection whose tunnel signs in as whoever runs it: with this Mac's agent, or its keys.
    private func teamRow(_ auth: SSHAuthMethod, keyPath: String = "") -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Orders", host: "db.team.example", port: 5_432, type: .postgresql)
        var ssh = SSHConfiguration(enabled: true, host: "127.0.0.1")
        ssh.port = 1
        ssh.username = "ops"
        ssh.authMethod = auth
        ssh.privateKeyPath = keyPath
        connection.sshTunnelMode = .inline(ssh)
        connection.origin = .teamLibrary
        return connection
    }

    private func withJump(_ connection: DatabaseConnection, _ jump: SSHJumpHost) -> DatabaseConnection {
        var routed = connection
        var ssh = connection.resolvedSSHConfig
        ssh.jumpHosts = [jump]
        routed.sshTunnelMode = .inline(ssh)
        return routed
    }

    @Test("A team row that would sign in with this Mac's SSH agent asks first, naming the server")
    func teamRowUsingTheAgentAsks() async throws {
        spy.answer = .approved
        let connection = teamRow(.sshAgent)
        #expect(makeConsent().requiresApproval(connection))

        try await makeConsent().check(connection, trigger: .request)

        let question = try #require(spy.questions.first)
        #expect(question.uses == ["SSH Agent: 127.0.0.1:1"])
        #expect(question.destination.contains("127.0.0.1:1"))
        #expect(question.origin == .teamLibrary)
    }

    @Test("A linked folder's row names its key and each hop's agent with the host, and a password tunnel asks nothing")
    func linkedRowNamesEachUse() async throws {
        spy.answer = .approved
        var linked = withJump(
            teamRow(.privateKey, keyPath: "~/.ssh/id_ed25519"),
            SSHJumpHost(host: "edge.example", username: "a", authMethod: .sshAgent)
        )
        linked.origin = .linkedFolder

        try await makeConsent().check(linked, trigger: .request)
        try await makeConsent().check(teamRow(.password), trigger: .request)

        #expect(spy.questions.map(\.uses) == [["Private Key: ~/.ssh/id_ed25519, 127.0.0.1:1", "SSH Agent: edge.example:22"]])
    }

    @Test("A hop only ~/.ssh/config names signs in with the agent, so it asks too")
    func configProxyJumpAsks() async throws {
        spy.answer = .approved
        let config = "Host 127.0.0.1\n  ProxyJump gate\nHost gate\n  User ops\n"

        try await makeConsent(sshConfig: config).check(teamRow(.password), trigger: .request)

        #expect(spy.questions.first?.uses == ["SSH Agent: gate:22"])
    }

    @Test("A HostName that moves behind the same alias asks again, naming the server it resolves to")
    func movedHostNameAsksAgain() async throws {
        spy.answer = .approved
        var aliased = teamRow(.sshAgent)
        var ssh = aliased.resolvedSSHConfig
        ssh.host = "bastion"
        ssh.port = nil
        aliased.sshTunnelMode = .inline(ssh)

        try await makeConsent(sshConfig: "Host bastion\n  HostName a.example\n").check(aliased, trigger: .request)
        try await makeConsent(sshConfig: "Host bastion\n  HostName a.example\n").check(aliased, trigger: .request)
        try await makeConsent(sshConfig: "Host bastion\n  HostName b.example\n").check(aliased, trigger: .request)

        #expect(spy.questions.map(\.uses) == [["SSH Agent: a.example:22"], ["SSH Agent: b.example:22"]])
    }

    @Test("A chain that changes while the question is open is asked about again, so the approval is what was read")
    func changeDuringTheQuestionAsksAgain() async throws {
        spy.answer = .approved
        let reads = ReadCounter()
        let consent = LocalCredentialConsent(
            approvals: store,
            ask: { [spy] question in await spy.ask(question) },
            sshDocument: {
                let host = await reads.next() == 0 ? "a.example" : "b.example"
                return SSHConfigParser.parseDocumentContent("Host 127.0.0.1\n  HostName \(host)\n")
            }
        )

        try await consent.check(teamRow(.sshAgent), trigger: .request)

        #expect(spy.questions.map(\.uses) == [["SSH Agent: a.example:1"], ["SSH Agent: b.example:1"]])
    }

    @Test("An agent hop's fallback key is approved with it, and a changed one asks again")
    func agentHopFallbackKeyAsksAgain() async throws {
        spy.answer = .approved
        let first = withJump(
            teamRow(.password),
            SSHJumpHost(host: "edge.example", username: "a", authMethod: .sshAgent, privateKeyPath: "~/.ssh/edge")
        )
        var changed = first.resolvedSSHConfig
        changed.jumpHosts[0].privateKeyPath = "~/.ssh/other"
        var second = first
        second.sshTunnelMode = .inline(changed)

        try await makeConsent().check(first, trigger: .request)
        try await makeConsent().check(second, trigger: .request)

        #expect(spy.questions.map(\.uses) == [
            ["SSH Agent: edge.example:22", "Private Key: ~/.ssh/edge, edge.example:22"],
            ["SSH Agent: edge.example:22", "Private Key: ~/.ssh/other, edge.example:22"],
        ])
    }

    @Test("A team row that opens a database file here asks once, and a MotherDuck one asks nothing")
    func teamRowOpeningAFileAsksOnce() async throws {
        spy.answer = .approved
        var file = DatabaseConnection(name: "Local", database: "/tmp/team-copy.sqlite", type: .sqlite)
        file.origin = .teamLibrary
        var motherDuck = DatabaseConnection(
            name: "Cloud",
            type: .duckdb,
            additionalFields: ["duckdbMode": "motherduck", "duckdbFilePath": "md:analytics"]
        )
        motherDuck.origin = .teamLibrary

        try await makeConsent().check(file, trigger: .request)
        try await makeConsent().check(file, trigger: .background)

        #expect(spy.questions.map(\.uses) == [["Database File: /tmp/team-copy.sqlite"]])
        #expect(!makeConsent().requiresApproval(motherDuck))
        var socket = DatabaseConnection(name: "PG", host: "/run/postgresql", port: 5_432, type: .postgresql)
        socket.origin = .teamLibrary
        #expect(socket.sharedRowLocalUses(sshUses: []) == [.file(path: "/run/postgresql")])
    }

    @Test("The same tunnel and file on a row of this Mac's own asks nothing")
    func ownRowDoesNotAsk() {
        var own = teamRow(.privateKey)
        own.origin = .thisMac

        #expect(own.sharedRowLocalUses(sshUses: [.agent(socket: "", server: "127.0.0.1:1")]).isEmpty)
        #expect(!makeConsent().requiresApproval(own))
    }

    @Test("An unapproved team row never reaches the SSH tunnel, from a connect or a Test")
    func unapprovedTeamRowNeverDials() async throws {
        let manager = DatabaseManager(localCredentialConsent: makeConsent())
        let connection = teamRow(.privateKey)

        await #expect(throws: LocalCredentialConsentError.declined) {
            try await manager.connectToSession(connection, trigger: .request)
        }
        await #expect(throws: LocalCredentialConsentError.declined) {
            _ = try await manager.testConnection(connection)
        }

        #expect(spy.questions.count == 2)
        #expect(await !SSHTunnelManager.shared.hasTunnel(connectionId: connection.id))
        #expect(manager.activeSessions[connection.id] == nil)
    }

    @Test("An approved team row goes on to its tunnel without asking again")
    func approvedTeamRowDoesNotAskAgain() async throws {
        spy.answer = .approved
        let connection = teamRow(.sshAgent)
        let consent = makeConsent()
        #expect(await consent.confirm(connection))
        spy.answer = .declined
        let manager = DatabaseManager(localCredentialConsent: consent)

        do {
            try await manager.connectToSession(connection, trigger: .background)
            Issue.record("Nothing listens on the SSH server's port")
        } catch let error as LocalCredentialConsentError {
            Issue.record("The approved row was asked again: \(error)")
        } catch {}

        #expect(spy.questions.count == 1)
        #expect(!consent.requiresApproval(connection))
    }
}
