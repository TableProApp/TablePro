import Foundation

struct DamengConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 30_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int
    let reconnectMilliseconds: Int

    init(additionalFields: [String: String]) {
        let seconds = additionalFields["connectTimeoutSeconds"].flatMap(Self.parseSeconds)
        reconnectMilliseconds = seconds ?? Self.defaultMilliseconds
        if let raw = additionalFields["connectTimeoutMilliseconds"] {
            milliseconds = Self.parseMilliseconds(raw) ?? Self.defaultMilliseconds
        } else {
            milliseconds = reconnectMilliseconds
        }
    }

    private static func parseMilliseconds(_ raw: String) -> Int? {
        guard let value = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return clamp(value)
    }

    private static func parseSeconds(_ raw: String) -> Int? {
        guard let seconds = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000)
        let milliseconds = multiplied.overflow ? (seconds > 0 ? Int64.max : Int64.min) : multiplied.partialValue
        return clamp(milliseconds)
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

final class DamengConnectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var settled = false
    private var terminalError: (any Error)?

    func arm(_ continuation: CheckedContinuation<Void, any Error>) {
        let error: (any Error)? = lock.withLock {
            guard !settled else { return terminalError ?? CancellationError() }
            self.continuation = continuation
            return nil
        }
        if let error { continuation.resume(throwing: error) }
    }

    func finish(with result: Result<Void, any Error>) {
        take()?.resume(with: result)
    }

    func fail(_ error: any Error, beforeResume: () -> Void) {
        let resolution: (won: Bool, continuation: CheckedContinuation<Void, any Error>?) = lock.withLock {
            guard !settled else { return (false, nil) }
            settled = true
            terminalError = error
            defer { continuation = nil }
            return (true, continuation)
        }
        guard resolution.won else { return }
        beforeResume()
        resolution.continuation?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, any Error>? {
        lock.withLock {
            guard !settled else { return nil }
            settled = true
            defer { continuation = nil }
            return continuation
        }
    }
}
