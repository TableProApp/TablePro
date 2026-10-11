//
//  MySQLBlockingPasswordRefreshTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct MySQLBlockingPasswordRefreshTests {
    private func waitOnDispatchQueue(
        _ refresh: @escaping @Sendable () async throws -> String,
        timeout: DispatchTimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: MySQLBlockingPasswordRefresh.wait(for: refresh, timeout: timeout))
            }
        }
    }

    @Test("A dispatch queue gets the password the host minted")
    func returnsTheMintedPassword() async {
        let password = await waitOnDispatchQueue({ "fresh-token" }, timeout: .seconds(5))
        #expect(password == "fresh-token")
    }

    @Test("A refresh that fails or outlasts the wait gives no password")
    func failureAndTimeoutGiveNothing() async {
        struct RefreshFailed: Error {}
        #expect(await waitOnDispatchQueue({ throw RefreshFailed() }, timeout: .seconds(5)) == nil)

        let started = ContinuousClock.now
        let slow = await waitOnDispatchQueue({
            try await Task.sleep(for: .seconds(30))
            return "late"
        }, timeout: .milliseconds(100))
        #expect(slow == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

struct DriverConnectionConfigRefreshTests {
    @Test("A later sign-in uses the configured password unless the host can mint a new one")
    func passwordForNewSignIn() async throws {
        let plain = DriverConnectionConfig(host: "db", port: 3_306, username: "u", password: "stored", database: "")
        #expect(plain.refreshPassword == nil)
        #expect(try await plain.passwordForNewSignIn() == "stored")

        let token = DriverConnectionConfig(
            host: "db",
            port: 3_306,
            username: "u",
            password: "first-token",
            database: "",
            refreshPassword: { "second-token" }
        )
        #expect(try await token.passwordForNewSignIn() == "second-token")
    }
}
