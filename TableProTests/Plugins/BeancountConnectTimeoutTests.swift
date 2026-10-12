//
//  BeancountConnectTimeoutTests.swift
//  TableProTests
//

import Darwin
import Foundation
import TableProPluginKit
import Testing

private enum BeancountConnectOutcome: Equatable, Sendable {
    case connected
    case cancelled
    case failed(String)
}

extension BeancountPluginDriverTests {
    @Test("connect timeout stops and reaps a cancellation-deaf backend")
    func connectTimeoutStopsHangingBackend() async throws {
        try await Self.withHangingPythonBackend { ledger, processIdentifierFile in
            let driver = BeancountPluginDriver(config: Self.timeoutConfig(
                ledger,
                additionalFields: ["connectTimeoutMilliseconds": "1000"]
            ))
            defer { driver.disconnect() }

            let start = ContinuousClock.now
            let connectTask = Task { await Self.connectOutcome(driver) }
            defer { connectTask.cancel() }
            let processIdentifier = try #require(await Self.waitForProcessIdentifier(at: processIdentifierFile))
            let outcome = await BoundedCall.result(
                onDeadline: { Darwin.kill(processIdentifier, SIGKILL) }
            ) {
                await connectTask.value
            }
            let elapsed = start.duration(to: .now)

            let resolvedOutcome = try #require(outcome)
            guard case .failed(let message) = resolvedOutcome else {
                Issue.record("Expected connect timeout, got \(resolvedOutcome)")
                return
            }
            #expect(message.contains("Connection timed out"))
            #expect(elapsed < .seconds(2))

            #expect(await Self.waitForProcessExit(processIdentifier))
        }
    }

    @Test("task cancellation stops and reaps a cancellation-deaf backend")
    func cancellationStopsHangingBackend() async throws {
        try await Self.withHangingPythonBackend { ledger, processIdentifierFile in
            let driver = BeancountPluginDriver(config: Self.timeoutConfig(
                ledger,
                additionalFields: ["connectTimeoutSeconds": "30"]
            ))
            defer { driver.disconnect() }

            let connectTask = Task { await Self.connectOutcome(driver) }
            defer { connectTask.cancel() }
            let processIdentifier = try #require(await Self.waitForProcessIdentifier(at: processIdentifierFile))
            defer { Darwin.kill(processIdentifier, SIGKILL) }

            let start = ContinuousClock.now
            connectTask.cancel()
            let outcome = await BoundedCall.result(
                onDeadline: { Darwin.kill(processIdentifier, SIGKILL) }
            ) {
                await connectTask.value
            }
            let elapsed = start.duration(to: .now)

            #expect(try #require(outcome) == .cancelled)
            #expect(elapsed < .seconds(2))
            #expect(await Self.waitForProcessExit(processIdentifier))
        }
    }

    private static func connectOutcome(_ driver: BeancountPluginDriver) async -> BeancountConnectOutcome {
        do {
            try await driver.connect()
            return .connected
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func withHangingPythonBackend(
        _ body: (URL, URL) async throws -> Void
    ) async throws {
        let directory = try makeTimeoutTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("python3")
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$TABLEPRO_BEANCOUNT_TEST_PID_FILE"
        while :; do :; done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let ledger = directory.appendingPathComponent("main.beancount")
        try "".write(to: ledger, atomically: true, encoding: .utf8)
        let processIdentifierFile = directory.appendingPathComponent("backend.pid")

        try await withTimeoutEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": executable.path,
            "TABLEPRO_BEANCOUNT_TEST_PID_FILE": processIdentifierFile.path
        ]) {
            try await body(ledger, processIdentifierFile)
        }
    }

    private static func processIdentifier(at fileURL: URL) async -> pid_t? {
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8),
              let processIdentifier = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return processIdentifier
    }

    private static func waitForProcessIdentifier(at fileURL: URL) async -> pid_t? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let processIdentifier = await processIdentifier(at: fileURL) {
                return processIdentifier
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private static func waitForProcessExit(_ processIdentifier: pid_t) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return Darwin.kill(processIdentifier, 0) == -1 && errno == ESRCH
    }

    private static func timeoutConfig(
        _ ledger: URL,
        additionalFields: [String: String]
    ) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: ledger.path,
            additionalFields: additionalFields
        )
    }

    private static func withTimeoutEnvironment<T>(
        _ values: [String: String],
        _ body: () async throws -> T
    ) async throws -> T {
        let previous = values.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (name, value) in values {
            setenv(name, value, 1)
        }
        defer {
            for (name, previousValue) in previous {
                if let previousValue {
                    setenv(name, previousValue, 1)
                } else {
                    unsetenv(name)
                }
            }
        }
        return try await body()
    }

    private static func makeTimeoutTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
