import Foundation
import os

public enum MCPBridgeLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol MCPBridgeLogger: Sendable {
    func log(_ level: MCPBridgeLogLevel, _ message: String)
}

public struct MCPOSBridgeLogger: MCPBridgeLogger {
    private let logger: Logger

    public init(subsystem: String = "com.TablePro", category: String = "MCP.Bridge") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func log(_ level: MCPBridgeLogLevel, _ message: String) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}

public struct MCPStderrBridgeLogger: MCPBridgeLogger {
    private let writer: StderrWriter

    public init() {
        writer = StderrWriter()
    }

    public func log(_ level: MCPBridgeLogLevel, _ message: String) {
        let prefix: String
        switch level {
        case .debug: prefix = "[debug] "
        case .info: prefix = "[info] "
        case .warning: prefix = "[warn] "
        case .error: prefix = "[error] "
        }
        writer.write(prefix + message + "\n")
    }
}

public struct MCPCompositeBridgeLogger: MCPBridgeLogger {
    private let loggers: [MCPBridgeLogger]

    public init(_ loggers: [MCPBridgeLogger]) {
        self.loggers = loggers
    }

    public func log(_ level: MCPBridgeLogLevel, _ message: String) {
        for logger in loggers {
            logger.log(level, message)
        }
    }
}

private final class StderrWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(handle: FileHandle = .standardError) {
        self.handle = handle
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle.write(data)
    }
}
