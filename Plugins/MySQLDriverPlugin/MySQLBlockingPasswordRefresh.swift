//
//  MySQLBlockingPasswordRefresh.swift
//  MySQLDriverPlugin
//

import Foundation
import os

/// Waits on a dispatch queue for the host to mint a password. Never call it from a Swift
/// concurrency thread: the refresh runs on one, and the host's refresh never needs the main actor.
internal enum MySQLBlockingPasswordRefresh {
    static func wait(
        for refresh: @escaping @Sendable () async throws -> String,
        timeout: DispatchTimeInterval
    ) -> String? {
        let result = OSAllocatedUnfairLock<String?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let password = try? await refresh()
            result.withLock { $0 = password }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return nil
        }
        return result.withLock { $0 }
    }
}
