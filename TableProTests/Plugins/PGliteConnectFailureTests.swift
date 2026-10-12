//
//  PGliteConnectFailureTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PGliteConnectFailureTests {
    private static func libpqError(_ message: String) -> LibPQPluginError {
        LibPQPluginError(message: message, sqlState: nil, detail: nil)
    }

    private static let missingDatabase = libpqError(
        "connection to server at \"127.0.0.1\", port 5432 failed: FATAL:  database \"nope\" does not exist"
    )

    private static let refusedLogin = libpqError(
        "connection to server at \"127.0.0.1\", port 5432 failed: FATAL:  password authentication failed for user \"app\""
    )

    private static let refusedConnection = libpqError(
        """
        connection to server at "127.0.0.1", port 5432 failed: Connection refused
        \tIs the server running on that host and accepting TCP/IP connections?
        """
    )

    private static let unknownHost = libpqError(
        "could not translate host name \"pglite.invalid\" to address: nodename nor servname provided, or not known"
    )

    private static func isPresentedAsUnreachable(_ error: Error) -> Bool {
        PGliteConnectFailure.presented(error, host: "127.0.0.1", port: 5_432) is PGliteConnectionError
    }

    @Test("A failure the server answered is not reported as an unreachable server")
    func serverAnswersAreNotUnreachable() {
        #expect(!Self.isPresentedAsUnreachable(Self.missingDatabase))
        #expect(!Self.isPresentedAsUnreachable(Self.refusedLogin))
    }

    @Test("A failure that never reached a server is reported as unreachable")
    func transportFailuresAreUnreachable() {
        #expect(Self.isPresentedAsUnreachable(Self.refusedConnection))
        #expect(Self.isPresentedAsUnreachable(Self.unknownHost))
        #expect(Self.isPresentedAsUnreachable(LibPQPluginError.connectionTimedOut))
        #expect(Self.isPresentedAsUnreachable(LibPQPluginError.connectionFailed))
    }

    @Test("The server's own answer reaches the user unchanged")
    func serverAnswerPassesThrough() throws {
        let presented = PGliteConnectFailure.presented(Self.missingDatabase, host: "127.0.0.1", port: 5_432)
        let error = try #require(presented as? LibPQPluginError)
        #expect(error.message == Self.missingDatabase.message)
    }

    @Test("An unreachable server is explained with the address and the reason")
    func unreachableServerIsExplained() throws {
        let presented = PGliteConnectFailure.presented(Self.refusedConnection, host: "127.0.0.1", port: 5_432)
        let error = try #require(presented as? PGliteConnectionError)
        #expect(error.pluginErrorMessage.contains("127.0.0.1:5432"))
        #expect(error.pluginErrorDetail == Self.refusedConnection.message)
    }

    @Test("A refused login through PGlite still reads as an authentication failure")
    @MainActor
    func refusedLoginStillPromptsForCredentials() {
        let presented = PGliteConnectFailure.presented(Self.refusedLogin, host: "127.0.0.1", port: 5_432)
        #expect(DatabaseManager.shared.isAuthenticationFailure(presented))
    }
}
