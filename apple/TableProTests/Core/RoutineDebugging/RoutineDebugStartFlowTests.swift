//
//  RoutineDebugStartFlowTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class FlowRecorder {
    var moduleEnabled = true
    var prepared: [RoutineDebugPick] = []
    var sheets = 0
    var openedScopes: [DatabaseScope] = []
    var failures = 0
    var opened: Int { openedScopes.count }

    func flow(
        onPrepare: @escaping @MainActor () -> Void = {},
        onSheet: @escaping @MainActor () -> Void = {}
    ) -> RoutineDebugStartFlow {
        RoutineDebugStartFlow(
            isModuleEnabled: { self.moduleEnabled },
            prepare: { pick in
                self.prepared.append(pick)
                onPrepare()
                return RoutineDebugFixtures.plan()
            },
            presentStartSheet: { _, _ in
                self.sheets += 1
                onSheet()
                return RoutineDebugStartChoice(entryPoint: RoutineDebugFixtures.entryPoint, arguments: [], optionValues: [:])
            },
            reportFailure: { _, _ in self.failures += 1 },
            open: { _, _, scope in self.openedScopes.append(scope) }
        )
    }
}

private let connectionId = UUID()
private let salesPick = RoutineDebugPick(
    target: RoutineDebugFixtures.target,
    scope: DatabaseScope(connectionId: connectionId, database: "sales", schema: "public")
)

@MainActor
struct RoutineDebugStartFlowTests {
    @Test("A routine chosen after the module went off reads nothing and shows no start sheet")
    func chooserAnsweredAfterModuleOff() async {
        let recorder = FlowRecorder()
        let setup = RoutineDebugSetup()

        await recorder.flow().choose(setup: setup) { _ in
            recorder.moduleEnabled = false
            return salesPick
        }

        #expect(recorder.prepared.isEmpty)
        #expect(recorder.sheets == 0)
        #expect(recorder.opened == 0)
    }

    @Test("A setup cancelled while the plan loads shows no start sheet and opens no tab")
    func cancelledWhilePreparing() async {
        let recorder = FlowRecorder()
        let setup = RoutineDebugSetup()

        await recorder.flow(onPrepare: { setup.cancel() }).run(salesPick, setup: setup)

        #expect(recorder.prepared.count == 1)
        #expect(recorder.sheets == 0)
        #expect(recorder.opened == 0)
    }

    @Test("With the module on, a chosen routine reaches its start sheet and its tab")
    func completeFlowOpensTheTab() async {
        let recorder = FlowRecorder()

        await recorder.flow().choose(setup: RoutineDebugSetup()) { _ in salesPick }

        #expect(recorder.prepared == [salesPick])
        #expect(recorder.sheets == 1)
        #expect(recorder.opened == 1)
    }

    @Test("A routine keeps the database it was chosen in when the browse database moves before it starts")
    func chosenDatabaseIsFrozen() async {
        let recorder = FlowRecorder()
        var browseDatabase = "sales"

        await recorder.flow(onSheet: { browseDatabase = "hr" }).choose(setup: RoutineDebugSetup()) { _ in
            RoutineDebugPick(
                RoutineDebugFixtures.target,
                listedIn: DatabaseScope(connectionId: connectionId, database: browseDatabase, schema: "public")
            )
        }

        #expect(browseDatabase == "hr")
        #expect(recorder.prepared.map { $0.scope.database } == ["sales"])
        #expect(recorder.openedScopes.map { $0.database } == ["sales"])
    }

    @Test("A chooser pick takes the listed database and the routine's own schema")
    func pickTakesTheListedDatabase() {
        let listed = DatabaseScope(connectionId: connectionId, database: "sales", schema: "reporting")
        let target = PluginDebugTarget(identity: "1", name: "f", schema: "public", kindDisplayName: "Function")
        let unqualified = PluginDebugTarget(identity: "2", name: "g", schema: nil, kindDisplayName: "Function")

        #expect(RoutineDebugPick(target, listedIn: listed).scope
            == DatabaseScope(connectionId: connectionId, database: "sales", schema: "public"))
        #expect(RoutineDebugPick(unqualified, listedIn: listed).scope == listed)
    }

    @Test("Turning the module off dismisses every chooser and start sheet still on screen")
    func moduleOffCancelsPendingSetups() async throws {
        let center = NotificationCenter()
        let registry = RoutineDebugSessions(isModuleEnabled: { false }, notificationCenter: center)
        let setup = RoutineDebugSetup()
        var dismissed = false
        setup.dismissPresentation = { dismissed = true }
        registry.beginSetup(setup)

        center.post(name: .appModulesDidChange, object: AppModule.routineDebugger)
        try await waitUntil { setup.isCancelled }

        #expect(dismissed)
        registry.endSetup(setup)
    }
}
