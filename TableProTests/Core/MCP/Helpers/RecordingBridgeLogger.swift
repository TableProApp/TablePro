import Foundation
@testable import TablePro

final class RecordingBridgeLogger: MCPBridgeLogger, @unchecked Sendable {
    struct Entry: Sendable {
        let level: MCPBridgeLogLevel
        let message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func log(_ level: MCPBridgeLogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(level: level, message: message))
    }
}
