import AppKit
import TableProPluginKit

struct RoutineDebugMenuState: Equatable {
    var canChooseRoutine = false
    var performableCommands: Set<PluginDebugCommand> = []
    var canStop = false
    // The debug tab in front has source on screen with a caret, and is not ending.
    var canToggleBreakpoint = false
    var canRemoveAllBreakpoints = false
}

extension MainSplitViewController {
    static let routineDebugSelectors: Set<Selector> = [
        #selector(chooseRoutineToDebug(_:)),
        #selector(debugContinue(_:)),
        #selector(debugStepOver(_:)),
        #selector(debugStepInto(_:)),
        #selector(debugStepOut(_:)),
        #selector(debugStop(_:)),
        #selector(toggleBreakpoint(_:)),
        #selector(removeAllBreakpoints(_:)),
    ]

    @objc func chooseRoutineToDebug(_ sender: Any?) {
        guard let coordinator = routineDebugCoordinator, coordinator.canChooseRoutineToDebug() else { return }
        coordinator.chooseRoutineToDebug()
    }

    @objc func debugContinue(_ sender: Any?) {
        performDebugCommand(.continueExecution)
    }

    @objc func debugStepOver(_ sender: Any?) {
        performDebugCommand(.stepOver)
    }

    @objc func debugStepInto(_ sender: Any?) {
        performDebugCommand(.stepInto)
    }

    @objc func debugStepOut(_ sender: Any?) {
        performDebugCommand(.stepOut)
    }

    @objc func debugStop(_ sender: Any?) {
        guard let controller = frontRoutineDebugController, controller.canStop else { return }
        controller.stop()
    }

    @objc func toggleBreakpoint(_ sender: Any?) {
        frontRoutineDebugController?.toggleBreakpointAtCursor()
    }

    @objc func removeAllBreakpoints(_ sender: Any?) {
        guard let controller = frontRoutineDebugController, controller.canRemoveAllBreakpoints else { return }
        controller.removeAllBreakpoints()
    }

    var routineDebugMenuState: RoutineDebugMenuState {
        guard let coordinator = routineDebugCoordinator else { return RoutineDebugMenuState() }
        var state = RoutineDebugMenuState(canChooseRoutine: coordinator.canChooseRoutineToDebug())
        guard let controller = coordinator.frontRoutineDebugController else { return state }
        let commands: [PluginDebugCommand] = [.continueExecution, .stepOver, .stepInto, .stepOut]
        state.performableCommands = Set(commands.filter { controller.canPerform($0) })
        state.canStop = controller.canStop
        state.canToggleBreakpoint = controller.canToggleBreakpoint
        state.canRemoveAllBreakpoints = controller.canRemoveAllBreakpoints
        return state
    }

    // Nil while the module is off, so no command reaches the debugger's code.
    private var routineDebugCoordinator: MainContentCoordinator? {
        guard AppModuleSettings.shared.isEnabled(.routineDebugger) else { return nil }
        return commandActions?.coordinator
    }

    private var frontRoutineDebugController: RoutineDebugController? {
        routineDebugCoordinator?.frontRoutineDebugController
    }

    private func performDebugCommand(_ command: PluginDebugCommand) {
        guard let controller = frontRoutineDebugController, controller.canPerform(command) else { return }
        controller.perform(command)
    }
}
