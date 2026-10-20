//
//  PostDisconnectScripts.swift
//  TablePro
//

import Foundation
import os

struct PendingPostDisconnectScript: Equatable, Sendable {
    let script: String
    let context: ConnectionScriptContext
    let timeoutSeconds: Int
}

// Armed when a session's pre-connect script succeeds, fired once when that session ends.
@MainActor
final class PostDisconnectScripts {
    typealias Runner = @Sendable (PendingPostDisconnectScript) async -> Void

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PostDisconnectScripts")

    private let run: Runner
    private var armed: [UUID: PendingPostDisconnectScript] = [:]
    private var running: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var setupsInFlight = 0
    private var setupsSettled: [CheckedContinuation<Void, Never>] = []
    private(set) var isDraining = false

    init(run: @escaping Runner = PostDisconnectScripts.runAndLog) {
        self.run = run
    }

    func arm(_ script: PendingPostDisconnectScript, for connectionId: UUID) {
        armed[connectionId] = script
    }

    func isArmed(for connectionId: UUID) -> Bool {
        armed[connectionId] != nil
    }

    func fire(for connectionId: UUID) {
        guard let script = armed.removeValue(forKey: connectionId) else { return }
        let previous = running[connectionId]?.task
        let token = UUID()
        let task = Task { [run] in
            await previous?.value
            await run(script)
            if self.running[connectionId]?.token == token {
                self.running.removeValue(forKey: connectionId)
            }
        }
        running[connectionId] = (token, task)
    }

    // A new pre-connect script waits, or the old session's cleanup would undo what it sets up.
    func finish(for connectionId: UUID) async {
        await running[connectionId]?.task.value
    }

    // A pre-connect script still running at quit may yet arm a cleanup, so the drain waits for it.
    func setupStarted() {
        setupsInFlight += 1
    }

    func setupEnded() {
        setupsInFlight -= 1
        guard setupsInFlight == 0 else { return }
        let waiting = setupsSettled
        setupsSettled.removeAll()
        waiting.forEach { $0.resume() }
    }

    // Quitting ends every session without a disconnect, so this is their only chance to run.
    func fireAllAndWait(closingSessions closeSessions: ([UUID]) async -> Void = { _ in }) async {
        isDraining = true
        if setupsInFlight > 0 {
            await withCheckedContinuation { setupsSettled.append($0) }
        }
        await closeSessions(Array(armed.keys))
        for connectionId in Array(armed.keys) {
            fire(for: connectionId)
        }
        while let entry = running.values.first {
            await entry.task.value
        }
    }

    nonisolated static func runAndLog(_ pending: PendingPostDisconnectScript) async {
        let name = pending.context.connectionName
        do {
            let outcome = try await ConnectionScriptRunner.run(
                pending.script,
                environment: pending.context.environment,
                timeoutSeconds: pending.timeoutSeconds
            )
            switch outcome {
            case .succeeded:
                logger.info("Post-disconnect script for \(name) finished")
            case let .failed(exitCode, stderr):
                logger.error("Post-disconnect script for \(name) exited with \(exitCode): \(stderr)")
            case .timedOut:
                logger.error("Post-disconnect script for \(name) timed out after \(pending.timeoutSeconds) seconds")
            }
        } catch {
            logger.error("Post-disconnect script for \(name) did not run: \(error.localizedDescription)")
        }
    }
}
