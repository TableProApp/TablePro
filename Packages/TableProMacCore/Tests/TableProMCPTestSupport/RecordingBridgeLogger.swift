import Foundation
import TableProMCP

public final class RecordingBridgeLogger: MCPBridgeLogger, @unchecked Sendable {
    public struct Entry: Sendable {
        public let level: MCPBridgeLogLevel
        public let message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    public init() {}

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func log(_ level: MCPBridgeLogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Entry(level: level, message: message))
    }
}
