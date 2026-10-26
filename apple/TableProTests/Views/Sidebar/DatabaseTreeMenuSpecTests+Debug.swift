import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

extension DatabaseTreeMenuSpecTests {
    private var debugRoutineRef: DatabaseTreeRoutineRef {
        DatabaseTreeRoutineRef(
            database: "app",
            schema: "public",
            routine: RoutineInfo(
                name: "order_total",
                kind: .function,
                schema: "public",
                argumentSignature: "(integer)",
                language: "plpgsql"
            )
        )
    }

    private var debugTarget: PluginDebugTarget {
        PluginDebugTarget(identity: "16431", name: "order_total", schema: "public", kindDisplayName: "Function")
    }

    @Test("A routine the driver can debug offers Debug… alone in a last section, after Show DDL")
    func debugSitsAfterShowDDL() throws {
        let ref = debugRoutineRef
        var debuggable = context(clicked: .routine(ref))
        debuggable.canDebugRoutine = true
        let sections = DatabaseTreeMenuSpec.sections(for: debuggable)

        try #require(sections.count == 3)
        #expect(commands([sections[1]]) == [.showObjectSource(ref.objectRef)])
        #expect(commands([sections[2]]) == [.debugRoutine(ref)])
        let item = try #require(sections.last?.items.first)
        guard case .command(let entry) = item else {
            Issue.record("Debug… is not a command")
            return
        }
        #expect(entry.title == String(localized: "Debug…"))
    }

    @Test("A routine nothing can debug keeps its two sections")
    func noDebugWithoutATarget() {
        let ref = debugRoutineRef
        let sections = DatabaseTreeMenuSpec.sections(for: context(clicked: .routine(ref)))

        #expect(sections.count == 2)
        #expect(!commands(sections).contains(.debugRoutine(ref)))
    }

    @Test("Debug… asks the module before the driver, and only for a routine row")
    @MainActor
    func debugAvailabilityAsksTheModuleFirst() throws {
        let suite = try EphemeralDefaults()
        let modules = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
        let ref = debugRoutineRef
        let target = debugTarget
        var asked: [RoutineInfo] = []

        let whileOff = DatabaseTreeMenuContext.canDebugRoutine(.routine(ref), modules: modules) {
            asked.append($0)
            return target
        }
        #expect(!whileOff)
        #expect(asked.isEmpty)

        modules.setEnabled(true, for: .routineDebugger)
        let withTarget = DatabaseTreeMenuContext.canDebugRoutine(.routine(ref), modules: modules) {
            asked.append($0)
            return target
        }
        let withoutTarget = DatabaseTreeMenuContext.canDebugRoutine(.routine(ref), modules: modules) { _ in nil }
        let onATable = DatabaseTreeMenuContext.canDebugRoutine(.table(tableRef("orders")), modules: modules) { _ in
            target
        }

        #expect(withTarget)
        #expect(!withoutTarget)
        #expect(!onATable)
        #expect(asked == [ref.routine])
    }
}
