//
//  MainContentCoordinator+RoutineDebugging.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    // Answers without I/O, so a context menu or a menu validation can ask. Every read goes through another driver.
    private var routineDebugger: (any PluginDatabaseDriver & PluginRoutineDebugging)? {
        guard AppModuleSettings.shared.isEnabled(.routineDebugger),
              connection.type.supportsConnectionPooling,
              let adapter = services.databaseManager.driver(for: connectionId) as? PluginDriverAdapter,
              let debugger = adapter.schemaPluginDriver as? any PluginDatabaseDriver & PluginRoutineDebugging,
              debugger.canDebugRoutines
        else { return nil }
        return debugger
    }

    func routineDebugTarget(for routine: RoutineInfo) -> PluginDebugTarget? {
        routineDebugger?.debugTarget(for: routine.pluginRoutine)
    }

    func canChooseRoutineToDebug() -> Bool {
        routineDebugger != nil && services.databaseManager.session(for: connectionId)?.isConnected == true
    }

    func debugRoutine(_ routine: RoutineInfo) {
        debugRoutine(routine, database: nil, schema: nil)
    }

    // A sidebar row names its own database and schema, which the run keeps whatever the browse cursor does meanwhile.
    func debugRoutine(_ routine: RoutineInfo, database: String?, schema: String?) {
        guard let target = routineDebugTarget(for: routine),
              let pick = routineDebugPick(for: target, routine: routine, database: database, schema: schema)
        else { return }
        launchDebugging { flow, setup in
            await flow.run(pick, setup: setup)
        }
    }

    // Read once, at the click; a database the row does not name is the one being browsed.
    func routineDebugPick(
        for target: PluginDebugTarget,
        routine: RoutineInfo,
        database: String?,
        schema: String?
    ) -> RoutineDebugPick? {
        guard let scope = services.databaseManager.resolvedScope(
            database: database,
            schema: schema ?? target.schema ?? routine.schema,
            for: connectionId
        ) else { return nil }
        return RoutineDebugPick(target: target, scope: scope)
    }

    // The chooser lists one database and schema; whatever is chosen from it keeps that database.
    func chooseRoutineToDebug() {
        guard canChooseRoutineToDebug(), let listed = browseScope else { return }
        let databaseManager = services.databaseManager
        launchDebugging { [weak self] flow, setup in
            await flow.choose(setup: setup) { chooserSetup in
                guard let window = self?.contentWindow else { return nil }
                let target = await RoutineDebugChooserSheet.present(on: window, setup: chooserSetup) {
                    guard AppModuleSettings.shared.isEnabled(.routineDebugger) else { throw CancellationError() }
                    return try await databaseManager.withMetadataDriver(scope: listed) { driver in
                        try await Self.metadataDebugger(driver).debugTargets(schema: listed.schema)
                    }
                }
                return target.map { RoutineDebugPick($0, listedIn: listed) }
            }
        }
    }

    var frontRoutineDebugController: RoutineDebugController? {
        guard let tab = tabManager.selectedTab, tab.tabType == .routineDebug else { return nil }
        return RoutineDebugSessions.shared.controller(forTab: tab.id)
    }

    // Not a user close: nothing goes to Reopen Closed Tab and the saved tab set is left alone.
    func closeRoutineDebugTabs() {
        let ids = tabManager.tabs.filter { $0.tabType == .routineDebug }.map(\.id)
        for id in ids {
            closeRoutineDebugTab(id)
        }
    }

    // MARK: - Starting a run

    // The setup is tracked until the flow ends, so turning the module off dismisses whatever it has on screen.
    private func launchDebugging(
        _ body: @escaping @MainActor (RoutineDebugStartFlow, RoutineDebugSetup) async -> Void
    ) {
        // Read before anything waits: a disconnect or reconnect while a sheet is up makes this start stale.
        let generation = RoutineDebugSessions.shared.admissionGeneration(for: connectionId)
        let setup = RoutineDebugSetup()
        let flow = startFlow(generation: generation)
        RoutineDebugSessions.shared.beginSetup(setup)
        Task {
            await body(flow, setup)
            RoutineDebugSessions.shared.endSetup(setup)
        }
    }

    private func startFlow(generation: Int) -> RoutineDebugStartFlow {
        let databaseManager = services.databaseManager
        let options = RoutineDebugOptionStore()
        let connectionId = connectionId
        return RoutineDebugStartFlow(
            isModuleEnabled: { AppModuleSettings.shared.isEnabled(.routineDebugger) },
            prepare: { pick in
                let target = pick.target
                return try await databaseManager.withMetadataDriver(scope: pick.scope) { driver in
                    try await Self.metadataDebugger(driver).prepareDebug(target)
                }
            },
            presentStartSheet: { [weak self] plan, setup in
                guard let window = self?.contentWindow else { return nil }
                let choice = await RoutineDebugStartSheet.present(
                    plan: plan,
                    rememberedOption: { fieldId in options.value(for: fieldId, connectionId: connectionId) },
                    on: window,
                    setup: setup
                )
                if let choice {
                    options.save(RoutineDebugStartSheet.rememberedValues(of: choice, in: plan), connectionId: connectionId)
                }
                return choice
            },
            reportFailure: { [weak self] target, error in
                guard !(error is CancellationError) else { return }
                AlertHelper.showErrorSheet(
                    title: String(format: String(localized: "Can't Debug %@"), target.name),
                    message: RoutineDebugController.message(for: error),
                    window: self?.contentWindow
                )
            },
            open: { [weak self] plan, choice, scope in
                self?.openRoutineDebugTab(plan: plan, choice: choice, scope: scope, generation: generation)
            }
        )
    }

    private func openRoutineDebugTab(
        plan: PluginDebugPlan,
        choice: RoutineDebugStartChoice,
        scope: DatabaseScope,
        generation: Int
    ) {
        // Read again: the connection may have reconnected, or the module gone off, while the sheet was up.
        guard let debugger = routineDebugger else { return }
        guard RoutineDebugSessions.shared.admits(connectionId, generation: generation) else {
            AlertHelper.showErrorSheet(
                title: String(format: String(localized: "Can't Debug %@"), plan.target.name),
                message: RoutineDebugError.connectionChanged.localizedDescription,
                window: contentWindow
            )
            return
        }
        let tabId = UUID()
        let preparationSetup = RoutineDebugSetup()
        let controller = RoutineDebugController(
            plan: plan,
            choice: choice,
            connectionId: connectionId,
            databaseType: connection.type,
            debugger: debugger,
            sessionSource: RoutineDebugSessionSource.live(scope: scope, generation: generation),
            gate: executionGate,
            confirmPreparation: { [weak self] preparation in
                await RoutineDebugPreparationPrompt.confirm(
                    preparation,
                    window: self?.contentWindow,
                    setup: preparationSetup
                )
            },
            withdrawPreparation: { preparationSetup.cancel() }
        )
        controller.onCancelled = { [weak self] in
            self?.closeRoutineDebugTab(tabId)
        }
        guard RoutineDebugSessions.shared.register(
            controller,
            tabId: tabId,
            connectionId: connectionId,
            generation: generation
        ) else { return }
        tabManager.addRoutineDebugTab(
            id: tabId,
            title: QueryTabManager.routineDebugTitle(for: plan.target.name),
            databaseName: scope.database,
            schemaName: scope.schema
        )
        controller.start()
    }

    private func closeRoutineDebugTab(_ tabId: UUID) {
        RoutineDebugSessions.shared.endSession(forTab: tabId, window: contentWindow)
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else { return }
        tabManager.closeTab(id: tabId)
    }

    // The pooled metadata driver for this read, which is the plugin's own driver behind the adapter.
    nonisolated private static func metadataDebugger(
        _ driver: DatabaseDriver
    ) throws -> any PluginDatabaseDriver & PluginRoutineDebugging {
        guard let adapter = driver as? PluginDriverAdapter,
              let debugger = adapter.schemaPluginDriver as? any PluginDatabaseDriver & PluginRoutineDebugging
        else { throw RoutineDebugError.unsupported }
        return debugger
    }
}
