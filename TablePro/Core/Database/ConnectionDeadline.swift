import Foundation

enum ConnectionTimeoutPolicy {
    static let defaultConnectTimeoutSeconds = 30
    static let connectTimeoutRange = 1 ... 600

    static func effectiveConnectTimeoutSeconds(configuredSeconds: Int?) -> Int {
        guard let configuredSeconds, connectTimeoutRange.contains(configuredSeconds) else {
            return defaultConnectTimeoutSeconds
        }
        return configuredSeconds
    }

    static func effectiveQueryTimeoutSeconds(configuredSeconds: Int?, globalSeconds: Int) -> Int {
        guard let configuredSeconds, configuredSeconds >= 0 else {
            return max(0, globalSeconds)
        }
        return configuredSeconds
    }

    static func requiresHostDeadline(for connection: DatabaseConnection) -> Bool {
        switch connection.type {
        case .sqlite:
            return connection.additionalFields[RemoteSQLiteWire.backendFieldKey]
                == RemoteSQLiteWire.agentBackendValue
        case .libsql, .turso:
            return connection.additionalFields["libsqlMode"] != "local"
        default:
            return true
        }
    }
}

enum ConnectionTimeoutEndpoint: Sendable, Equatable {
    case database(String)
    case tunnel(String)
    case proxy(String)
    case remoteFile(String)

    var name: String {
        switch self {
        case .database(let name), .tunnel(let name), .proxy(let name), .remoteFile(let name):
            return name
        }
    }
}

struct ConnectionTimeoutError: Error, LocalizedError, Sendable, Equatable {
    let endpoint: ConnectionTimeoutEndpoint
    let configuredSeconds: Int

    var errorDescription: String? {
        String(
            format: String(localized: "Connecting to '%@' timed out after %lld seconds."),
            endpoint.name,
            Int64(configuredSeconds)
        )
    }
}

struct ConnectionDeadline: Sendable, Equatable {
    let configuredSeconds: Int
    let instant: ContinuousClock.Instant

    init(configuredSeconds: Int?, startedAt: ContinuousClock.Instant = .now) {
        let effectiveSeconds = ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(
            configuredSeconds: configuredSeconds
        )
        self.init(
            configuredSeconds: effectiveSeconds,
            instant: startedAt.advanced(by: .seconds(effectiveSeconds))
        )
    }

    init(configuredSeconds: Int, instant: ContinuousClock.Instant) {
        let effectiveSeconds = ConnectionTimeoutPolicy.effectiveConnectTimeoutSeconds(
            configuredSeconds: configuredSeconds
        )
        self.configuredSeconds = effectiveSeconds
        self.instant = instant
    }

    var remainingDuration: Duration {
        remainingDuration(at: .now)
    }

    var remainingSeconds: Int {
        remainingSeconds(at: .now)
    }

    var remainingMilliseconds: Int {
        remainingMilliseconds(at: .now)
    }

    var isExpired: Bool {
        isExpired(at: .now)
    }

    func remainingDuration(at now: ContinuousClock.Instant) -> Duration {
        guard now < instant else { return .zero }
        return now.duration(to: instant)
    }

    func remainingSeconds(at now: ContinuousClock.Instant) -> Int {
        let milliseconds = roundedUpMilliseconds(at: now)
        return (milliseconds + 999) / 1_000
    }

    func remainingMilliseconds(at now: ContinuousClock.Instant) -> Int {
        roundedUpMilliseconds(at: now)
    }

    func isExpired(at now: ContinuousClock.Instant) -> Bool {
        now >= instant
    }

    func timeoutError(for endpoint: ConnectionTimeoutEndpoint) -> ConnectionTimeoutError {
        ConnectionTimeoutError(endpoint: endpoint, configuredSeconds: configuredSeconds)
    }

    func check(endpoint: ConnectionTimeoutEndpoint, at now: ContinuousClock.Instant = .now) throws {
        try Task.checkCancellation()
        guard !isExpired(at: now) else { throw timeoutError(for: endpoint) }
    }

    private func roundedUpMilliseconds(at now: ContinuousClock.Instant) -> Int {
        let components = remainingDuration(at: now).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(ceil(milliseconds))
    }
}

final class ConnectionSingleResumeGate<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var pendingResult: Result<Value, Error>?
        var isResolved = false
    }

    private let state = NSLock()
    private var value = State()

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Value, Error>? = state.withLock {
                if let pendingResult = value.pendingResult {
                    value.pendingResult = nil
                    return pendingResult
                }
                value.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    @discardableResult
    func resume(
        with result: Result<Value, Error>,
        beforeResuming: () -> Void = {}
    ) -> Bool {
        let resolution = state.withLock {
            guard !value.isResolved else {
                return (false, nil as CheckedContinuation<Value, Error>?)
            }
            value.isResolved = true
            guard let continuation = value.continuation else {
                value.pendingResult = result
                return (true, nil)
            }
            value.continuation = nil
            return (true, continuation)
        }
        guard resolution.0 else { return false }
        beforeResuming()
        resolution.1?.resume(with: result)
        return true
    }
}
