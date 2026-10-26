//
//  RoutineDebugStartFlow.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One pending way into a debug run: the chooser, the start sheet, or a preparation alert. Cancelling it, as turning the
// module off does, answers whatever is on screen as declined and stops the flow at its next step.
@MainActor
internal final class RoutineDebugSetup {
    private(set) var isCancelled = false
    var dismissPresentation: (@MainActor () -> Void)?

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let dismiss = dismissPresentation
        dismissPresentation = nil
        dismiss?()
    }
}

// A routine and the database and schema it was chosen in, frozen at that moment: an oid or an owner-qualified name only
// means something there, and another window can move this connection's browse database while a sheet is up.
internal struct RoutineDebugPick: Sendable, Equatable {
    let target: PluginDebugTarget
    let scope: DatabaseScope

    // A chooser lists one database and schema: the pick keeps that database and the routine's own schema.
    init(_ target: PluginDebugTarget, listedIn listed: DatabaseScope) {
        self.target = target
        self.scope = DatabaseScope(
            connectionId: listed.connectionId,
            database: listed.database,
            schema: target.schema ?? listed.schema
        )
    }

    init(target: PluginDebugTarget, scope: DatabaseScope) {
        self.target = target
        self.scope = scope
    }
}

// From a chosen routine to an open debug tab. Every step that reads the database or shows something asks first
// whether the module is still on and the setup still wanted, because each one can wait on the person for a while.
@MainActor
internal struct RoutineDebugStartFlow {
    var isModuleEnabled: @MainActor () -> Bool
    var prepare: @MainActor (RoutineDebugPick) async throws -> PluginDebugPlan
    var presentStartSheet: @MainActor (PluginDebugPlan, RoutineDebugSetup) async -> RoutineDebugStartChoice?
    var reportFailure: @MainActor (PluginDebugTarget, any Error) -> Void
    var open: @MainActor (PluginDebugPlan, RoutineDebugStartChoice, DatabaseScope) -> Void

    func choose(
        setup: RoutineDebugSetup,
        presentChooser: @MainActor (RoutineDebugSetup) async -> RoutineDebugPick?
    ) async {
        guard proceeds(setup), let pick = await presentChooser(setup) else { return }
        await run(pick, setup: setup)
    }

    func run(_ pick: RoutineDebugPick, setup: RoutineDebugSetup) async {
        guard proceeds(setup) else { return }
        let plan: PluginDebugPlan
        do {
            plan = try await prepare(pick)
        } catch {
            guard proceeds(setup) else { return }
            reportFailure(pick.target, error)
            return
        }
        guard proceeds(setup), let choice = await presentStartSheet(plan, setup), proceeds(setup) else { return }
        open(plan, choice, pick.scope)
    }

    private func proceeds(_ setup: RoutineDebugSetup) -> Bool {
        !setup.isCancelled && isModuleEnabled()
    }
}
