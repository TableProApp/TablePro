//
//  LocalCredentialConsentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
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

    private func makeConsent() -> LocalCredentialConsent {
        LocalCredentialConsent(approvals: store, ask: { [spy] question in await spy.ask(question) })
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
            .appendingPathComponent("tablepro-signin-bridge-\(UUID().uuidString).json")
        let storageSuite = try EphemeralDefaults()
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: storageSuite.defaults, keychain: InMemoryKeychain())
        storage.addConnection(connection)
        let manager = DatabaseManager(connectionStorage: storage, localCredentialConsent: makeConsent())
        return (DatabaseAccessBridge(manager: manager), {
            manager.removeSession(for: connection.id)
            storageSuite.defaults.removePersistentDomain(forName: storageSuite.suiteName)
            try? FileManager.default.removeItem(at: fileURL)
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
}
