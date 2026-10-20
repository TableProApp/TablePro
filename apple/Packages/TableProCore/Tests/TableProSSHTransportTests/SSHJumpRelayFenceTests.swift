//
//  SSHJumpRelayFenceTests.swift
//  TableProSSHTransportTests
//

import Foundation
import os
import TableProTestSupport
import Testing

@testable import TableProSSHTransport

struct SSHJumpRelayFenceTests {
    @Test("ProxyJump cleanup waits until its relay no longer uses libssh2 handles")
    func proxyJumpCleanupDrainsRelayBeforeFree() async {
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

        guard (try? await waitUntil(timeout: .seconds(1)) { enteredRelay.withLock { $0 } }) != nil else {
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
