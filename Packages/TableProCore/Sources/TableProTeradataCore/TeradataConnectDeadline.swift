import Foundation

struct TeradataConnectDeadline: Sendable {
    private let expiresAt: TimeInterval

    init(milliseconds: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expiresAt = now + TimeInterval(milliseconds) / 1_000
    }

    func remainingMilliseconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Int {
        let remaining = Int(((expiresAt - now) * 1_000).rounded(.up))
        guard remaining > 0 else {
            throw TeradataWireError.connectionFailed("connect timed out")
        }
        return remaining
    }
}
