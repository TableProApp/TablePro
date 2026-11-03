import Foundation
@testable import TablePro
import Testing

@MainActor
struct RunningWorkTests {
    private func work(
        _ kind: RunningWorkKind,
        subject: String = "orders",
        connectionIds: Set<UUID> = [UUID()],
        windowId: UUID? = nil,
        tabId: UUID? = nil,
        cancel: @escaping @MainActor () -> Void = {}
    ) -> RunningWork {
        RunningWork(
            kind: kind,
            subject: subject,
            connectionName: "Production",
            connectionIds: connectionIds,
            windowId: windowId,
            tabId: tabId,
            cancel: cancel
        )
    }

    @Test("Work ends when its job ends, on every path")
    func beginAndEnd() {
        let registry = RunningWorkRegistry(providers: [])
        let connectionId = UUID()
        let id = registry.begin(.dataImport, subject: "users.csv", connectionName: "Production", connectionIds: [connectionId]) {}

        #expect(registry.items(in: .app).map(\.id) == [id])
        registry.end(id)
        registry.end(id)
        registry.end(nil)

        #expect(registry.items(in: .app).isEmpty)
    }

    @Test("Pushed and pulled work are listed together, in start order")
    func providersJoinTheList() {
        let pulled = work(.agentReply)
        let registry = RunningWorkRegistry(providers: [{ [pulled] }])
        let pushed = registry.begin(.backup, subject: "sales", connectionName: "Production", connectionIds: [UUID()]) {}

        #expect(registry.items(in: .app).map(\.id) == [pushed, pulled.id])
    }

    @Test("A connection scope takes work on either end of a transfer")
    func connectionScopeMatchesEitherEnd() {
        let source = UUID()
        let destination = UUID()
        let transfer = work(.tableTransfer, connectionIds: [source, destination])
        let other = work(.dataExport)
        let registry = RunningWorkRegistry(providers: [{ [transfer, other] }])

        #expect(registry.items(in: .connection(destination)).map(\.id) == [transfer.id])
        #expect(registry.items(in: .connection(source)).map(\.id) == [transfer.id])
    }

    @Test("A window scope takes its own queries and any other work on its connections")
    func windowScope() {
        let connectionId = UUID()
        let thisWindow = UUID()
        let ownQuery = work(.query, connectionIds: [connectionId], windowId: thisWindow, tabId: UUID())
        let otherWindowQuery = work(.query, connectionIds: [connectionId], windowId: UUID(), tabId: UUID())
        let restore = work(.restore, connectionIds: [connectionId])
        let elsewhere = work(.restore)
        let registry = RunningWorkRegistry(providers: [{ [ownQuery, otherWindowQuery, restore, elsewhere] }])

        let scoped = registry.items(in: .window(ids: [thisWindow], connectionIds: [connectionId]))

        #expect(scoped.map(\.id) == [ownQuery.id, restore.id])
    }

    @Test("A tab scope takes only the queries of those tabs")
    func tabScope() {
        let tabId = UUID()
        let query = work(.query, tabId: tabId)
        let restore = work(.restore)
        let registry = RunningWorkRegistry(providers: [{ [query, restore] }])

        #expect(registry.items(in: .tabs([tabId])).map(\.id) == [query.id])
    }

    @Test("Cancelling runs each job's own cancel")
    func cancelReachesEachJob() {
        var cancelled: [String] = []
        let registry = RunningWorkRegistry(providers: [])
        registry.begin(.dataImport, subject: "a", connectionName: "", connectionIds: []) { cancelled.append("a") }
        registry.begin(.dataExport, subject: "b", connectionName: "", connectionIds: []) { cancelled.append("b") }

        registry.cancel(registry.items(in: .app))

        #expect(cancelled == ["a", "b"])
    }

    @Test("Nothing running asks nothing, even with other losses")
    func noWorkNoPrompt() {
        #expect(RunningWorkPrompt.make(action: .quit, work: [], otherLosses: ["Unsaved edits in open tabs"]) == nil)
    }

    @Test("Each closer names its own action on the title and the button")
    func titlesAndButtons() throws {
        let job = [work(.dataExport)]
        let quit = try #require(RunningWorkPrompt.make(action: .quit, work: job))
        let relaunch = try #require(RunningWorkPrompt.make(action: .relaunch, work: job))
        let close = try #require(RunningWorkPrompt.make(action: .close, work: job))
        let disconnect = try #require(RunningWorkPrompt.make(action: .disconnect, work: job))

        #expect(quit.confirmButton == "Quit Anyway")
        #expect(relaunch.confirmButton == "Relaunch Anyway")
        #expect(close.confirmButton == "Close Anyway")
        #expect(disconnect.confirmButton == "Disconnect Anyway")
        #expect(quit.title == "Quit while work is still running?")
        #expect(disconnect.title == "Disconnect while work is still running?")
    }

    @Test("The message lists every job, then the other losses, then what stopping means")
    func messageListsWork() throws {
        let prompt = try #require(RunningWorkPrompt.make(
            action: .close,
            work: [work(.restore, subject: "sales"), work(.query, subject: "Query 2")],
            otherLosses: RunningWorkPrompt.transactionLines(for: ["app"])
        ))

        #expect(prompt.message.hasPrefix("""
        Restoring “sales” on Production
        Running query in “Query 2” on Production
        Open transaction in “app”

        Closing stops this work.
        """))
        #expect(prompt.message.contains("partly restored"))
        #expect(!prompt.message.contains("\u{2014}"))
    }

    @Test("The save question names the running work only when there is some")
    func saveMessageCarriesWork() {
        let base = "Your changes will be lost if you don't save them."

        #expect(RunningWorkPrompt.saveMessage(base, action: .close, alsoStopping: []) == base)
        #expect(RunningWorkPrompt.saveMessage(base, action: .close, alsoStopping: [work(.restore, subject: "sales")]) == """
        Your changes will be lost if you don't save them.

        Restoring “sales” on Production

        Closing stops this work.

        A stopped restore can leave the database partly restored.
        """)
    }

    @Test("The quit a relaunch starts stops the approved work without asking again")
    func relaunchApprovedQuitStopsWork() {
        var stopped = 0
        let registry = RunningWorkRegistry(providers: [])
        registry.begin(.restore, subject: "sales", connectionName: "", connectionIds: []) { stopped += 1 }

        #expect(QuitApproval.approve(registry: registry, relaunchApproved: true))
        #expect(stopped == 1)
    }

    @Test("A sync apply says statements already run stay applied")
    func syncApplyNote() throws {
        let prompt = try #require(RunningWorkPrompt.make(action: .quit, work: [work(.compareApply, subject: "staging")]))

        #expect(prompt.message.contains("Applying a sync script to staging"))
        #expect(prompt.message.contains("stay applied"))
    }

    @Test("An unnamed import or export still reads as a sentence")
    func unnamedSubjects() {
        #expect(RunningWorkPrompt.line(for: work(.dataImport, subject: " ")) == "Importing into Production")
        #expect(RunningWorkPrompt.line(for: work(.dataExport, subject: "")) == "Exporting from Production")
    }

    @Test("An idle comparison is not running work; an apply is, on both of its connections")
    func compareWork() {
        let session = CompareSyncSession()
        #expect(CompareSyncRunRegistry.runningWork(for: session) == nil)

        let sourceId = UUID()
        let targetId = UUID()
        session.source = endpoint(connectionId: sourceId, name: "prod")
        session.target = endpoint(connectionId: targetId, name: "staging")
        session.activity = .comparing
        let comparison = CompareSyncRunRegistry.runningWork(for: session)
        #expect(comparison?.kind == .compareRun)
        #expect(comparison.map(RunningWorkPrompt.line(for:)) == "Comparing prod / app with staging / app")

        session.activity = .applying
        let apply = CompareSyncRunRegistry.runningWork(for: session)
        #expect(apply?.kind == .compareApply)
        #expect(apply?.connectionIds == [sourceId, targetId])
        #expect(apply?.subject == "staging / app")
    }

    @Test("A busy agent session is running work; a ready one is not")
    func agentWork() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunningWorkTests-\(UUID().uuidString)", isDirectory: true)
        let registry = AgentSessionRegistry(store: AgentSessionStore(directory: directory))
        let connectionId = UUID()
        let busy = registry.startSession(for: connectionId)
        let idle = registry.startSession(for: connectionId)
        busy.mark(.waitingOnYou)
        idle.mark(.ready)

        let items = RunningWorkProviders.agentReplies(in: registry.sessions)

        #expect(items.map(\.id) == [busy.id])
        #expect(items.first?.connectionIds == [connectionId])
    }

    @Test("A query run in an editor tab is running work; a table tab loading rows is not")
    func onlyEditorQueriesCount() {
        let fixture = CoordinatorFixture()
        let query = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query))
        let table = fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
        _ = fixture.coordinator.tabExecution.claim(query.id)
        _ = fixture.coordinator.tabExecution.claim(table.id)

        let items = RunningWorkProviders.queries(in: [fixture.coordinator, fixture.coordinator])

        #expect(items.map(\.tabId) == [query.id])
        #expect(items.first?.subject == "Query 1")
        #expect(items.first?.connectionIds == [fixture.connection.id])
    }

    private func endpoint(connectionId: UUID, name: String) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: "app", schema: nil),
            connectionName: name,
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }
}
