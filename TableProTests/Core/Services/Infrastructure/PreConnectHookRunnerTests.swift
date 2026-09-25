//
//  PreConnectHookRunnerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct PreConnectHookRunnerTests {
    private static let message = "vault login failed: token expired"

    private static func failureMessage() async -> String? {
        do {
            try await PreConnectHookRunner.run(script: "printf '%s' '\(Self.message)' >&2; exit 3")
            return nil
        } catch PreConnectHookRunner.HookError.scriptFailed(let exitCode, let stderr) {
            return exitCode == 3 ? stderr : nil
        } catch {
            return nil
        }
    }

    /// A script that writes its reason and exits at once can still have it in the pipe when the
    /// runner reads what it collected. Measured with sixteen scripts at a time: 352 of 16,000
    /// failures came back without their message before the pipe was drained on the way out, and 0
    /// of 16,000 after.
    @Test("A failing script's message reaches the error every time", .timeLimit(.minutes(1)))
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
}
