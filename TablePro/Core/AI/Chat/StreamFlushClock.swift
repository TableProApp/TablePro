//
//  StreamFlushClock.swift
//  TablePro
//

import Foundation

protocol StreamFlushClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousStreamFlushClock: StreamFlushClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
