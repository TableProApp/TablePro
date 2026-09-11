//
//  ConnectionWindowPhaseMachineTests.swift
//  TableProTests
//
//  A connection window used to derive its content from membership in
//  DatabaseManager.activeSessions, so a failed connect, a cancelled one and an
//  in-flight one were the same state: the window kept a spinner forever and a
//  one-way latch made it deaf to every later connection event.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection window phase machine")
struct ConnectionWindowPhaseMachineTests {
    private static let failure = ConnectionFailureInfo(
        message: "Could not connect to the server.",
        failureReason: "The server refused the connection.",
        recoverySuggestion: "Make sure the database server is running."
    )

    @Test("A failed attempt leaves the connecting phase")
    func failedAttemptLeavesConnecting() {
        let phase = ConnectionWindowPhaseMachine.onAttemptFinished(
            phase: .connecting,
            isCurrentAttempt: true,
            outcome: .failed(Self.failure)
        )

        #expect(phase == .unavailable(.failed(Self.failure)))
        #expect(phase != .connecting)
    }

    @Test("A cancelled attempt is not reported as a failure")
    func cancelledAttemptIsNotFailure() {
        let phase = ConnectionWindowPhaseMachine.onAttemptFinished(
            phase: .connecting,
            isCurrentAttempt: true,
            outcome: .cancelled
        )

        #expect(phase == .unavailable(.cancelled))
    }

    @Test("A failure that needs the user's fix keeps the fix it names")
    func actionRequiredKeepsItsAction() {
        let actions: [ConnectionRecoveryAction] = [
            .installPlugin,
            .enablePlugin(pluginId: "com.TablePro.SQLiteDriver"),
            .openPluginSettings(pluginId: nil),
            .editConnection
        ]

        for action in actions {
            let phase = ConnectionWindowPhaseMachine.onAttemptFinished(
                phase: .connecting,
                isCurrentAttempt: true,
                outcome: .actionRequired(Self.failure, action)
            )

            #expect(phase == .unavailable(.actionRequired(Self.failure, action)))
        }
    }

    @Test("Choosing a database type replaces Edit Connection with Connect")
    func recordChangeResetsAnEditRequest() {
        let editing = ConnectionWindowPhase.unavailable(.actionRequired(Self.failure, .editConnection))

        #expect(
            ConnectionWindowPhaseMachine.onConnectionRecordChanged(phase: editing, databaseTypeChanged: true)
                == .unavailable(.notConnected)
        )
    }

    /// A rename, a colour, a group move or a sync batch also reports the record as changed, and none
    /// of them fixes an unrecognized type, so Edit Connection has to survive them.
    @Test("An edit that leaves the database type alone keeps Edit Connection")
    func unrelatedRecordChangeKeepsTheEditRequest() {
        let editing = ConnectionWindowPhase.unavailable(.actionRequired(Self.failure, .editConnection))

        #expect(ConnectionWindowPhaseMachine.onConnectionRecordChanged(phase: editing, databaseTypeChanged: false) == editing)
    }

    /// A fix offered for one database type names that type's plugin, so once the type changes it
    /// would enable or reveal a plugin the connection no longer uses.
    @Test("A new database type retires every fix offered for the old one")
    func typeChangeRetiresEveryAction() {
        let actions: [ConnectionRecoveryAction] = [
            .installPlugin,
            .enablePlugin(pluginId: "com.TablePro.SQLiteDriver"),
            .openPluginSettings(pluginId: nil),
            .editConnection
        ]

        for action in actions {
            let phase = ConnectionWindowPhase.unavailable(.actionRequired(Self.failure, action))
            #expect(
                ConnectionWindowPhaseMachine.onConnectionRecordChanged(phase: phase, databaseTypeChanged: true)
                    == .unavailable(.notConnected)
            )
        }
    }

    @Test("Editing the record leaves every phase without a fix alone")
    func recordChangeLeavesOtherPhases() {
        let phases: [ConnectionWindowPhase] = [
            .idle,
            .connecting,
            .connected,
            .closing,
            .unavailable(.failed(Self.failure)),
            .unavailable(.cancelled),
            .unavailable(.disconnectedByUser)
        ]

        for phase in phases {
            #expect(ConnectionWindowPhaseMachine.onConnectionRecordChanged(phase: phase, databaseTypeChanged: true) == phase)
        }
    }

    @Test("A failure reported from outside the window lands only where nothing newer owns the phase")
    func externalFailureRespectsTheAttemptFence() {
        #expect(ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .connecting, ownsAttempt: false))
        #expect(ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .unavailable(.disconnected(nil)), ownsAttempt: false))
        #expect(ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .unavailable(.failed(Self.failure)), ownsAttempt: false))

        #expect(!ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .connecting, ownsAttempt: true))
        #expect(!ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .unavailable(.cancelled), ownsAttempt: false))
        #expect(!ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .unavailable(.disconnectedByUser), ownsAttempt: false))
        #expect(!ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .connected, ownsAttempt: false))
        #expect(!ConnectionWindowPhaseMachine.acceptsExternalFailure(phase: .closing, ownsAttempt: false))
    }

    @Test("An outcome from a superseded attempt never moves the phase")
    func supersededAttemptIsIgnored() {
        let phase = ConnectionWindowPhaseMachine.onAttemptFinished(
            phase: .connecting,
            isCurrentAttempt: false,
            outcome: .failed(Self.failure)
        )

        #expect(phase == .connecting)
    }

    @Test("A driver appearing recovers the window from every unavailable reason")
    func driverRecoversFromEveryUnavailableReason() {
        let reasons: [ConnectionUnavailableReason] = [
            .cancelled,
            .disconnected(nil),
            .failed(Self.failure),
            .actionRequired(Self.failure, .installPlugin)
        ]

        for reason in reasons {
            let phase = ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .unavailable(reason),
                session: ConnectionSessionSnapshot(exists: true, hasDriver: true),
                ownsAttempt: false
            )

            #expect(phase == .connected, "\(reason) should recover once a driver exists")
        }
    }

    @Test("A closing window absorbs every event")
    func closingIsAbsorbing() {
        let session = ConnectionSessionSnapshot(exists: true, hasDriver: true)

        #expect(ConnectionWindowPhaseMachine.onAttemptStarted(phase: .closing) == .closing)
        #expect(
            ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .closing, session: session, ownsAttempt: true
            ) == .closing
        )
        #expect(
            ConnectionWindowPhaseMachine.onAttemptFinished(
                phase: .closing, isCurrentAttempt: true, outcome: .failed(Self.failure)
            ) == .closing
        )
        #expect(
            ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .closing, session: .absent, ownsAttempt: false
            ) == .closing
        )
    }

    @Test("A session removed under our own attempt keeps connecting")
    func ownedAttemptKeepsConnectingWhenSessionDisappears() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connecting,
            session: .absent,
            ownsAttempt: true
        )

        #expect(phase == .connecting)
    }

    @Test("A session removed by someone else ends the connecting phase")
    func unownedAttemptBecomesDisconnected() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connecting,
            session: .absent,
            ownsAttempt: false
        )

        #expect(phase == .unavailable(.disconnected(nil)))
    }

    @Test("Losing a live session becomes disconnected, not connecting")
    func connectedSessionLossBecomesDisconnected() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: .absent,
            ownsAttempt: false
        )

        #expect(phase == .unavailable(.disconnected(nil)))
    }

    @Test("A session torn down with a reason reports the reason, not the generic close")
    func disconnectReasonReachesThePhase() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: ConnectionSessionSnapshot(exists: false, hasDriver: false, disconnectInfo: Self.failure),
            ownsAttempt: false
        )

        #expect(phase == .unavailable(.disconnected(Self.failure)))
        #expect(phase != .unavailable(.disconnected(nil)))
    }

    @Test("A driverless session does not drag an unavailable window back to a spinner")
    func unavailableStaysPutForDriverlessSession() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .unavailable(.cancelled),
            session: ConnectionSessionSnapshot(exists: true, hasDriver: false),
            ownsAttempt: false
        )

        #expect(phase == .unavailable(.cancelled))
    }

    @Test("A failed connection is still worth reopening next launch")
    func failureRetainsRestoreIntent() {
        #expect(ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .unavailable(.failed(Self.failure))))
        #expect(ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .unavailable(.disconnected(nil))))
        #expect(ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .unavailable(.actionRequired(Self.failure, .editConnection))))
        #expect(ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .connecting))
        #expect(ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .connected))
    }

    @Test("A cancelled or closing window is not reopened next launch")
    func cancelDropsRestoreIntent() {
        #expect(!ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .unavailable(.cancelled)))
        #expect(!ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .closing))
        #expect(!ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .idle))
    }

    @Test("Activating a window retries a failure but never undoes a cancel")
    func activationConnectEligibility() {
        #expect(ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .idle))
        #expect(ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .unavailable(.failed(Self.failure))))
        #expect(ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .unavailable(.disconnected(nil))))

        #expect(!ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .unavailable(.cancelled)))
        #expect(!ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .unavailable(.actionRequired(Self.failure, .enablePlugin(pluginId: "p")))))
        #expect(!ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .connecting))
        #expect(!ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .connected))
        #expect(!ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .closing))
    }

    @Test("A session the user ended is not reported as a lost connection")
    func deliberateSessionLossIsDistinctFromLosingOne() {
        let deliberate = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: ConnectionSessionSnapshot(exists: false, hasDriver: false, wasDisconnectedByUser: true),
            ownsAttempt: false
        )
        let involuntary = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: .absent,
            ownsAttempt: false
        )

        #expect(deliberate == .unavailable(.disconnectedByUser))
        #expect(involuntary == .unavailable(.disconnected(nil)))
    }

    @Test("A window the user disconnected is not reopened next launch")
    func deliberateDisconnectDropsRestoreIntent() {
        #expect(!ConnectionWindowPhaseMachine.retainsRestoreIntent(phase: .unavailable(.disconnectedByUser)))
    }

    /// Clicking back into the window must not undo the disconnect, but Reconnect has to work, which
    /// is why the automatic and the manual connect answer this differently.
    @Test("A deliberate disconnect blocks the automatic connect but not Reconnect")
    func deliberateDisconnectConnectEligibility() {
        #expect(!ConnectionWindowPhaseMachine.allowsActivationConnect(phase: .unavailable(.disconnectedByUser)))
        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(phase: .unavailable(.disconnectedByUser)))
    }

    /// A failure whose fix lives in Settings or the connection form is fixed away from the window,
    /// so Reconnect has to stay available for the user to come back and try it.
    @Test("Reconnect is offered wherever a window has no session")
    func manualConnectEligibility() {
        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(phase: .idle))
        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(phase: .unavailable(.notConnected)))
        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(phase: .unavailable(.cancelled)))
        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(phase: .unavailable(.disconnected(nil))))
        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(phase: .unavailable(.failed(Self.failure))))

        #expect(ConnectionWindowPhaseMachine.allowsManualConnect(
            phase: .unavailable(.actionRequired(Self.failure, .openPluginSettings(pluginId: nil)))
        ))
        #expect(!ConnectionWindowPhaseMachine.allowsManualConnect(phase: .connecting))
        #expect(!ConnectionWindowPhaseMachine.allowsManualConnect(phase: .connected))
        #expect(!ConnectionWindowPhaseMachine.allowsManualConnect(phase: .closing))
    }
}
