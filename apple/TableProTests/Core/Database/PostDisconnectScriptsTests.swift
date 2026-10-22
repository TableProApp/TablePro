//
//  PostDisconnectScriptsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct PostDisconnectScriptsTests {
    private static func pending(_ script: String) -> PendingPostDisconnectScript {
        PendingPostDisconnectScript(
            script: script,
            context: ConnectionScriptContext(
                connectionId: UUID(), connectionName: "c", host: "h", port: 1, user: "u", database: "d"
            ),
            timeoutSeconds: 10
        )
    }

    @Test("A script fires once, and only when armed")
    func firesOnce() async {
        let events = EventLog()
        let scripts = PostDisconnectScripts(run: { await events.append($0.script) })
        let id = UUID()

        scripts.fire(for: id)
        scripts.arm(Self.pending("down"), for: id)
        scripts.fire(for: id)
        scripts.fire(for: id)
        await scripts.finish(for: id)

        #expect(await events.entries == ["down"])
        #expect(!scripts.isArmed(for: id))
    }

    @Test("The next connect waits for the last session's cleanup to finish")
    func finishWaitsForASlowCleanup() async {
        let events = EventLog()
        let gate = AsyncGate()
        let scripts = PostDisconnectScripts(run: { pending in
            await gate.wait()
            await events.append(pending.script)
        })
        let id = UUID()
        scripts.arm(Self.pending("cleanup"), for: id)
        scripts.fire(for: id)
        await gate.arrived(1)

        let reconnect = Task {
            await scripts.finish(for: id)
            await events.append("setup")
        }
        await gate.open()
        await reconnect.value

        #expect(await events.entries == ["cleanup", "setup"])
    }

    @Test("A pre-connect script that succeeds while quitting still gets its cleanup run")
    func setupDuringQuitIsDrained() async throws {
        let events = EventLog()
        let scripts = PostDisconnectScripts(run: { await events.append($0.script) })
        let id = UUID()
        scripts.setupStarted()

        let quit = Task { await scripts.fireAllAndWait() }
        try await waitUntil { scripts.isDraining }
        scripts.arm(Self.pending("late"), for: id)
        scripts.setupEnded()
        await quit.value

        #expect(await events.entries == ["late"])
    }
}

private actor EventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}
