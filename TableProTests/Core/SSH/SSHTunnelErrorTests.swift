//
//  SSHTunnelErrorTests.swift
//  TableProTests
//
//  Tests for SSHTunnelError descriptions and isLocalPortBindFailure classification.
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

struct SSHTunnelErrorTests {
    // MARK: - Port Bind Failure Classification

    @Test("isLocalPortBindFailure detects 'already in use' pattern")
    func bindFailureAlreadyInUse() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("Address already in use"))
    }

    @Test("isLocalPortBindFailure is case-insensitive")
    func bindFailureCaseInsensitive() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("ADDRESS ALREADY IN USE"))
    }

    @Test("isLocalPortBindFailure returns false for unrelated SSH errors")
    func nonBindFailures() {
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Permission denied"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Connection refused"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Host key verification failed"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure(""))
    }

    // MARK: - Error Descriptions

    @Test("SSHTunnelError.noAvailablePort has a localized description")
    func noAvailablePortDescription() {
        let error = SSHTunnelError.noAvailablePort
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("SSHTunnelError.authenticationFailed has a localized description")
    func authenticationFailedDescription() {
        let error = SSHTunnelError.authenticationFailed(reason: .generic)
        #expect(error.errorDescription != nil)
    }

    @Test("SSHTunnelError.tunnelAlreadyExists includes connection ID in description")
    func tunnelAlreadyExistsDescription() {
        let id = UUID()
        let error = SSHTunnelError.tunnelAlreadyExists(id)
        #expect(error.errorDescription?.contains(id.uuidString) == true)
    }

    @Test("A connection timeout names the SSH endpoint and configured budget")
    func connectionTimeoutDescription() {
        let error = ConnectionTimeoutError(
            endpoint: .tunnel("bastion.example:2222"),
            configuredSeconds: 17
        )

        #expect(error.errorDescription?.contains("bastion.example:2222") == true)
        #expect(error.errorDescription?.contains("17") == true)
    }

    @Test("SSHTunnelError.socketForwardingRefused names the socket and the sshd setting")
    func socketForwardingRefusedDescription() {
        let error = SSHTunnelError.socketForwardingRefused(
            path: "/var/run/postgresql/.s.PGSQL.5432",
            detail: "channel open failed"
        )

        #expect(error.errorDescription?.contains("/var/run/postgresql/.s.PGSQL.5432") == true)
        #expect(error.errorDescription?.contains("AllowStreamLocalForwarding") == true)
        #expect(error.errorDescription?.contains("channel open failed") == true)
    }

    @Test("SSHTunnelError.forwardRefused names the destination, the sshd setting, and the detail")
    func forwardRefusedDescription() {
        let error = SSHTunnelError.forwardRefused(
            destination: "db.internal:3306",
            detail: "channel open failure"
        )

        #expect(error.errorDescription?.contains("db.internal:3306") == true)
        #expect(error.errorDescription?.contains("AllowTcpForwarding") == true)
        #expect(error.errorDescription?.contains("channel open failure") == true)
    }

    @Test("SSHTunnelError.forwardRefused explains that the host resolves from the SSH server")
    func forwardRefusedExplainsResolutionSide() {
        let error = SSHTunnelError.forwardRefused(destination: "db.internal:3306", detail: "refused")

        #expect(error.errorDescription?.contains("127.0.0.1") == true)
        #expect(error.errorDescription?.contains("localhost") == true)
    }

    @Test("SSHTunnelError.forwardTimedOut names the destination and the seconds waited")
    func forwardTimedOutDescription() {
        let error = SSHTunnelError.forwardTimedOut(destination: "db.internal:3306", seconds: 6)

        #expect(error.errorDescription?.contains("db.internal:3306") == true)
        #expect(error.errorDescription?.contains("6") == true)
    }

    @Test("A missing SSH username is plain text that names the host")
    func usernameMissingDescription() {
        let description = SSHTunnelError.usernameMissing(host: "bastion.example").errorDescription ?? ""

        #expect(!description.contains("`"))
        #expect(description.contains("bastion.example"))
        #expect(description.contains("~/.ssh/config"))
    }

    @Test("A failed remote command is plain text that names the command")
    func remoteCommandFailedIsPlainText() {
        let description = SFTPError.remoteCommandFailed(
            command: "VACUUM INTO",
            status: 1,
            output: "disk I/O error"
        ).errorDescription ?? ""

        #expect(!description.contains("`"))
        #expect(description.contains("VACUUM INTO"))
        #expect(description.contains("disk I/O error"))
    }

    @Test("An expired SSH attempt interrupts its transport and keeps the bastion in the error")
    func expiredAttemptInterruptsTransport() {
        let deadline = ConnectionDeadline(configuredSeconds: 30, instant: .now)
        let endpoint = ConnectionTimeoutEndpoint.tunnel("jump.example:2200")
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: endpoint)
        let interrupted = OSAllocatedUnfairLock(initialState: false)
        _ = attempt.registerTransportInterrupt { interrupted.withLock { $0 = true } }

        #expect(throws: ConnectionTimeoutError(endpoint: endpoint, configuredSeconds: 30)) {
            try attempt.prepare(for: endpoint)
        }
        #expect(interrupted.withLock { $0 })
    }

    /// The dismissal is a main-actor job and this test runs off the main actor, so it waits for
    /// the dismissal itself. Yielding here never waited for the main actor, and every yield could
    /// pass before the main thread took its turn.
    @Test("Cancelling SSH authentication dismisses its active prompt")
    func cancellationDismissesPrompt() async throws {
        let deadline = ConnectionDeadline(configuredSeconds: 30)
        let endpoint = ConnectionTimeoutEndpoint.tunnel("jump.example:22")
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: endpoint)
        let (dismissals, dismissal) = AsyncStream<Void>.makeStream()
        let promptId = try attempt.registerPrompt(for: endpoint) {
            dismissal.yield()
            dismissal.finish()
        }

        attempt.cancel()

        let dismissed = await BoundedCall.result {
            for await _ in dismissals { return true }
            return false
        }

        #expect(dismissed == true)
        #expect(throws: CancellationError.self) {
            try attempt.check(for: endpoint)
        }
        attempt.unregisterPrompt(promptId)
    }

    @Test("SFTP reports exact deadline expiry against the remote-file endpoint")
    func sftpBudgetPreservesEndpointAtExactExpiry() {
        let startedAt = ContinuousClock.now
        let deadline = ConnectionDeadline(configuredSeconds: 60, startedAt: startedAt)
        let endpoint = ConnectionTimeoutEndpoint.remoteFile("files.example:2222")
        let budget = SFTPConnectionBudget(deadline: deadline, endpoint: endpoint)

        #expect(throws: ConnectionTimeoutError(endpoint: endpoint, configuredSeconds: 60)) {
            try budget.check(at: deadline.instant)
        }
    }

    @Test("SFTP chunk cancellation wins while deadline budget remains")
    func sftpBudgetHonorsCancellation() throws {
        let startedAt = ContinuousClock.now
        let deadline = ConnectionDeadline(configuredSeconds: 60, startedAt: startedAt)
        let budget = SFTPConnectionBudget(
            deadline: deadline,
            endpoint: .remoteFile("files.example:22")
        )

        #expect(throws: SFTPError.cancelled) {
            try budget.check(at: startedAt, isCancelled: { true })
        }
        #expect(try budget.remainingMilliseconds(
            at: startedAt.advanced(by: .seconds(15))
        ) == 45_000)
    }

    @Test("Cancelling SFTP wakes a read blocked on a silent transport")
    func sftpCancellationInterruptsBlockedTransport() async throws {
        let sockets = SocketPair()
        #expect(sockets.a >= 0)
        defer { sockets.close() }

        let descriptor = sockets.a
        let interrupt = SFTPTransportInterrupt(socketFD: descriptor)
        let cancellationFlag = CancellationFlag()
        let enteredRead = OSAllocatedUnfairLock(initialState: false)
        let blockedRead = Task {
            try await withTaskCancellationHandler {
                guard let readResult = await BoundedCall.resultOnItsOwnThread(
                    within: .seconds(2),
                    onDeadline: { Darwin.shutdown(descriptor, SHUT_RDWR) },
                    of: {
                        enteredRead.withLock { $0 = true }
                        var byte: UInt8 = 0
                        return Darwin.read(descriptor, &byte, 1)
                    }
                ) else {
                    throw SFTPError.cancelled
                }
                try Task.checkCancellation()
                return readResult
            } onCancel: {
                cancellationFlag.cancel()
                interrupt.interrupt()
            }
        }

        let entryDeadline = ContinuousClock.now + .seconds(1)
        while !enteredRead.withLock({ $0 }), ContinuousClock.now < entryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard enteredRead.withLock({ $0 }) else {
            blockedRead.cancel()
            Issue.record("The blackhole read did not start")
            _ = await blockedRead.result
            return
        }
        let startedAt = ContinuousClock.now
        blockedRead.cancel()
        let result = await blockedRead.result

        guard case .failure(let error) = result else {
            Issue.record("The cancelled SFTP read completed successfully")
            return
        }
        #expect(error is CancellationError)
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        #expect(cancellationFlag.isCancelled)
        #expect(interrupt.isInterrupted)
    }

    @Test("Closing SFTP interrupts once before the socket can change owners")
    func sftpCloseInterruptsOnceBeforeSocketRelease() {
        let interruptCount = OSAllocatedUnfairLock(initialState: 0)
        let interrupt = SFTPTransportInterrupt {
            interruptCount.withLock { $0 += 1 }
        }

        interrupt.interrupt()
        interrupt.interrupt()

        #expect(interruptCount.withLock { $0 } == 1)
        #expect(interrupt.isInterrupted)
    }

    @Test("SFTP close waits for the interrupted operation before cleanup")
    func sftpCloseUsesSerialCleanupBarrier() async throws {
        let releaseOperation = DispatchSemaphore(value: 0)
        let enteredOperation = OSAllocatedUnfairLock(initialState: false)
        let operationFinished = OSAllocatedUnfairLock(initialState: false)
        let cleanupObservedFinishedOperation = OSAllocatedUnfairLock(initialState: false)
        let lateOperationRan = OSAllocatedUnfairLock(initialState: false)
        let gate = SFTPSerialSessionGate(
            queue: DispatchQueue(label: "com.TableProTests.sftp-close-barrier"),
            transportInterrupt: SFTPTransportInterrupt {
                releaseOperation.signal()
            }
        )
        let operation = Task {
            await BoundedCall.resultOnItsOwnThread(
                within: .seconds(3),
                onDeadline: { releaseOperation.signal() },
                of: {
                    do {
                        try gate.withOpenSession {
                            enteredOperation.withLock { $0 = true }
                            releaseOperation.wait()
                            operationFinished.withLock { $0 = true }
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            )
        }

        let entryDeadline = ContinuousClock.now + .seconds(1)
        while !enteredOperation.withLock({ $0 }), ContinuousClock.now < entryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard enteredOperation.withLock({ $0 }) else {
            releaseOperation.signal()
            Issue.record("The serialized SFTP operation did not start")
            _ = await operation.value
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) {
            releaseOperation.signal()
        }
        let startedAt = ContinuousClock.now
        let didClose = gate.close {
            let operationDidFinish = operationFinished.withLock { $0 }
            cleanupObservedFinishedOperation.withLock { $0 = operationDidFinish }
        }
        let operationResult = await operation.value

        #expect(didClose)
        #expect(operationResult != nil)
        #expect(ContinuousClock.now - startedAt < .seconds(1))
        #expect(cleanupObservedFinishedOperation.withLock { $0 })
        #expect(throws: SFTPError.cancelled) {
            try gate.withOpenSession {
                lateOperationRan.withLock { $0 = true }
            }
        }
        #expect(!lateOperationRan.withLock { $0 })
    }

    @Test("ProxyJump cleanup waits until its relay no longer uses libssh2 handles")
    func proxyJumpCleanupDrainsRelayBeforeFree() async throws {
        let releaseRelay = DispatchSemaphore(value: 0)
        let enteredRelay = OSAllocatedUnfairLock(initialState: false)
        let relayFinished = OSAllocatedUnfairLock(initialState: false)
        let cleanupObservedFinishedRelay = OSAllocatedUnfairLock(initialState: false)
        let fence = SSHJumpRelayFence {
            releaseRelay.signal()
        }

        Thread.detachNewThread {
            enteredRelay.withLock { $0 = true }
            releaseRelay.wait()
            relayFinished.withLock { $0 = true }
            fence.finish()
        }

        let entryDeadline = ContinuousClock.now + .seconds(1)
        while !enteredRelay.withLock({ $0 }), ContinuousClock.now < entryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard enteredRelay.withLock({ $0 }) else {
            releaseRelay.signal()
            Issue.record("The ProxyJump relay did not start")
            return
        }

        let teardown = await BoundedCall.resultOnItsOwnThread(
            within: .seconds(2),
            onDeadline: { releaseRelay.signal() },
            of: {
                fence.stop()
                fence.wait()
                cleanupObservedFinishedRelay.withLock { value in
                    value = relayFinished.withLock { $0 }
                }
                return true
            }
        )

        #expect(teardown == true)
        #expect(cleanupObservedFinishedRelay.withLock { $0 })
        #expect(!fence.isActive)
    }

    @Test("A completed ProxyJump relay disarms late descriptor interruption")
    func proxyJumpCompletionDisarmsLateStop() {
        let stopCount = OSAllocatedUnfairLock(initialState: 0)
        let released = OSAllocatedUnfairLock(initialState: false)
        let fence = SSHJumpRelayFence {
            stopCount.withLock { $0 += 1 }
        }

        fence.finish {
            released.withLock { $0 = true }
        }
        fence.stop()

        #expect(released.withLock { $0 })
        #expect(stopCount.withLock { $0 } == 0)
        #expect(!fence.isActive)
    }
}
