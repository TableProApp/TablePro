//
//  ConnectionScriptRunnerTests.swift
//  TableProTests
//

import Foundation
import TableProTestSupport
import Testing

@testable import TablePro

struct ConnectionScriptRunnerTests {
    private static let message = "vault login failed: token expired"

    private static func failureMessage() async -> String? {
        let outcome = try? await ConnectionScriptRunner.run(
            "printf '%s' '\(Self.message)' >&2; exit 3",
            environment: [:],
            timeoutSeconds: 30
        )
        guard case let .failed(exitCode, stderr) = outcome, exitCode == 3 else { return nil }
        return stderr
    }

    @Test("A failing script's message reaches the outcome every time", .timeLimit(.minutes(1)))
    func failureCarriesTheScriptsMessage() async {
        for _ in 0 ..< 4 {
            let messages = await withTaskGroup(of: String?.self) { group in
                for _ in 0 ..< 16 {
                    group.addTask { await Self.failureMessage() }
                }
                var collected: [String?] = []
                for await message in group {
                    collected.append(message)
                }
                return collected
            }
            #expect(messages.allSatisfy { $0 == Self.message })
        }
    }

    @Test("The script sees the connection's variables and the tool paths a Dock launch lacks")
    func scriptSeesEnvironment() async throws {
        let outcome = try await ConnectionScriptRunner.run(
            #"[ "$TABLEPRO_HOST" = "db.example.com" ] && case ":$PATH:" in *:/opt/homebrew/bin:*) exit 0;; esac; exit 1"#,
            environment: ["TABLEPRO_HOST": "db.example.com"],
            timeoutSeconds: 30
        )
        #expect(outcome == .succeeded)
    }

    @Test("A script still running at its timeout is stopped and reported as timed out", .timeLimit(.minutes(1)))
    func slowScriptTimesOut() async throws {
        let clock = ManualClock()
        let run = Task {
            try await ConnectionScriptRunner.run("sleep 30", environment: [:], timeoutSeconds: 30, clock: clock)
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(30))
        #expect(try await run.value == .timedOut)
    }

    @Test("A script slower than the old 10 second limit finishes inside a longer timeout", .timeLimit(.minutes(1)))
    func longerTimeoutLetsTheScriptFinish() async throws {
        let clock = ManualClock()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tablepro-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let run = Task {
            try await ConnectionScriptRunner.run(
                "while [ ! -e '\(marker.path)' ]; do sleep 0.05; done",
                environment: [:],
                timeoutSeconds: 30,
                clock: clock
            )
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(15))
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        #expect(try await run.value == .succeeded)
    }

    @Test("A script that kills itself is a failure, not a timeout")
    func selfSignalIsAFailure() async throws {
        let outcome = try await ConnectionScriptRunner.run("kill -TERM $$", environment: [:], timeoutSeconds: 30)
        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
    }

    @Test("Cancelling the connect stops the script", .timeLimit(.minutes(1)))
    func cancellationStopsTheScript() async throws {
        let started = FileManager.default.temporaryDirectory.appendingPathComponent("tablepro-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: started) }
        let clock = ContinuousClock()
        let begin = clock.now
        let run = Task {
            try await ConnectionScriptRunner.run("touch '\(started.path)'; sleep 30", environment: [:], timeoutSeconds: 300)
        }
        try await waitUntil { FileManager.default.fileExists(atPath: started.path) }
        run.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(clock.now - begin < .seconds(20))
    }
}
