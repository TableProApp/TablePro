//
//  ConnectionFailureClassifierTests.swift
//  TableProTests
//
//  A cancelled connect must never be presented as an error, and a real failure
//  must keep the three strings the inline error pane renders.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection failure classifier")
struct ConnectionFailureClassifierTests {
    @Test("A Swift cancellation is a cancel, not a failure")
    func swiftCancellationIsCancelled() {
        #expect(ConnectionFailureClassifier.isUserCancelled(CancellationError()))
        #expect(ConnectionFailureClassifier.outcome(for: CancellationError()) == .cancelled)
    }

    @Test("A Cocoa user-cancelled error is a cancel")
    func cocoaUserCancelledIsCancelled() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

        #expect(ConnectionFailureClassifier.isUserCancelled(error))
        #expect(ConnectionFailureClassifier.outcome(for: error) == .cancelled)
    }

    @Test("A declined pre-connect prompt is a cancel")
    func routerCancellationIsCancelled() {
        #expect(ConnectionFailureClassifier.isUserCancelled(TabRouterError.userCancelled))
        #expect(ConnectionFailureClassifier.outcome(for: TabRouterError.userCancelled) == .cancelled)
    }

    @Test("An unrelated Cocoa error is not a cancel")
    func otherCocoaErrorIsNotCancelled() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        #expect(!ConnectionFailureClassifier.isUserCancelled(error))
    }

    @Test("A missing plugin is classified apart from a connection failure")
    func missingPluginIsItsOwnOutcome() {
        let outcome = ConnectionFailureClassifier.outcome(for: PluginError.pluginNotInstalled("mongodb"))

        guard case .pluginMissing = outcome else {
            Issue.record("Expected a pluginMissing outcome, got \(outcome)")
            return
        }
    }

    @Test("A failure keeps its description, reason and recovery suggestion")
    func failurePreservesAllThreeStrings() {
        let error = NSError(
            domain: "com.TablePro.test",
            code: 61,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not connect to PostgreSQL at localhost:5432.",
                NSLocalizedFailureReasonErrorKey: "The server refused the connection.",
                NSLocalizedRecoverySuggestionErrorKey: "Make sure the database server is running, then try again."
            ]
        )

        let info = ConnectionFailureClassifier.info(for: error)

        #expect(info.message == "Could not connect to PostgreSQL at localhost:5432.")
        #expect(info.failureReason == "The server refused the connection.")
        #expect(info.recoverySuggestion == "Make sure the database server is running, then try again.")
    }

    @Test("A failure without extra keys still carries a message")
    func failureWithoutExtrasStillHasMessage() {
        let error = NSError(
            domain: "com.TablePro.test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Connection refused."]
        )

        let info = ConnectionFailureClassifier.info(for: error)

        #expect(info.message == "Connection refused.")
        #expect(info.failureReason == nil)
        #expect(info.recoverySuggestion == nil)
    }

    @Test("A TLS failure is formatted the same way the rest of the app formats it")
    func tlsFailureUsesSharedFormatting() {
        let error = SSLHandshakeError.untrustedCertificate(serverMessage: "self signed certificate")

        let info = ConnectionFailureClassifier.info(for: error)

        #expect(info.message == SSLHandshakeError.formatted(error))
        #expect(info.message.contains("self signed certificate"))
    }

    @Test("A TLS failure never leaks credentials from the server message")
    func tlsFailureRedactsCredentials() {
        let error = SSLHandshakeError.untrustedCertificate(
            serverMessage: "failed for postgres://admin:hunter2@db.example.com/app"
        )

        let info = ConnectionFailureClassifier.info(for: error)

        #expect(!info.message.contains("hunter2"))
    }
}
