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

    @Test("Each driver failure offers the fix that matches its cause")
    func driverFailuresMapToTheirFix() {
        let cases: [(PluginError, ConnectionRecoveryAction)] = [
            (.pluginNotInstalled("MongoDB"), .installPlugin),
            (.pluginDisabled(pluginId: "com.TablePro.SQLiteDriver", pluginName: "SQLite Driver"),
             .enablePlugin(pluginId: "com.TablePro.SQLiteDriver")),
            (.pluginLoadFailed(pluginId: "com.example.driver", pluginName: "Example", reason: "bad signature"),
             .openPluginSettings(pluginId: "com.example.driver")),
            (.pluginUpdateUnavailable(reason: "No compatible build"), .openPluginSettings(pluginId: nil)),
            (.unknownDatabaseType("MicrosoftSQLServer"), .editConnection)
        ]

        for (error, action) in cases {
            let outcome = ConnectionFailureClassifier.outcome(for: error)
            #expect(outcome == .actionRequired(ConnectionFailureClassifier.info(for: error), action))
        }
    }

    @Test("An unrecognized database type is never sent to install a plugin")
    func unknownTypeNeverOffersInstall() {
        let action = ConnectionFailureClassifier.recoveryAction(for: PluginError.unknownDatabaseType("MicrosoftSQLServer"))

        #expect(action == .editConnection)
        #expect(action != .installPlugin)
    }

    @Test("A connection that cannot be edited is not offered Edit Connection")
    func uneditableConnectionGetsNoEditAction() {
        let error = PluginError.unknownDatabaseType("MicrosoftSQLServer")

        #expect(ConnectionFailureClassifier.recoveryAction(for: error, canEditConnection: false) == nil)
        #expect(
            ConnectionFailureClassifier.outcome(for: error, canEditConnection: false)
                == .failed(ConnectionFailureClassifier.info(for: error))
        )
    }

    @Test("A failed plugin install names its reason in the message every surface shows")
    func failedInstallMessageCarriesItsReason() {
        let error = PluginError.pluginInstallFailed(databaseType: "SQL Server", reason: "The registry is unreachable.")

        #expect(error.localizedDescription.contains("The registry is unreachable."))
        #expect(error.localizedDescription.contains("SQL Server"))
    }

    @Test("A failed plugin install is retried by connecting again, not by a separate fix")
    func failedInstallIsAPlainFailure() {
        let error = PluginError.pluginInstallFailed(databaseType: "SQL Server", reason: "offline")

        #expect(ConnectionFailureClassifier.recoveryAction(for: error) == nil)
        #expect(ConnectionFailureClassifier.outcome(for: error) == .failed(ConnectionFailureClassifier.info(for: error)))
    }

    @Test("A driver failure carries its reason and what to do about it")
    func driverFailureCarriesReasonAndSuggestion() {
        let info = ConnectionFailureClassifier.info(
            for: PluginError.pluginLoadFailed(pluginId: nil, pluginName: "Example", reason: "bad signature")
        )

        #expect(info.message.contains("Example"))
        #expect(info.failureReason == "bad signature")
        #expect(info.recoverySuggestion?.isEmpty == false)
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
