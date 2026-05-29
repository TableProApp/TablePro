import Foundation

public final class HttpQueryTimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HttpQueryTimeout

    public init(_ initial: HttpQueryTimeout = HttpQueryTimeout()) {
        self.stored = initial
    }

    public func set(serverTimeoutSeconds seconds: Int, graceSeconds grace: Int = HttpQueryTimeout.defaultGraceSeconds) {
        lock.lock()
        stored = HttpQueryTimeout(serverTimeoutSeconds: seconds, graceSeconds: grace)
        lock.unlock()
    }

    public var current: HttpQueryTimeout {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public var requestTimeoutInterval: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return stored.requestTimeoutInterval
    }
}
