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
    private static let lock = NSLock()

    public init() {}

    public func log(_ level: MCPBridgeLogLevel, _ message: String) {
        let prefix: String
        switch level {
        case .debug: prefix = "[debug] "
        case .info: prefix = "[info] "
        case .warning: prefix = "[warn] "
        case .error: prefix = "[error] "
        }
        let payload = prefix + message + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        FileHandle.standardError.write(data)
    }
}

public struct MCPCompositeBridgeLogger: MCPBridgeLogger {
    private let loggers: [any MCPBridgeLogger]

    public init(_ loggers: [any MCPBridgeLogger]) {
        self.loggers = loggers
    }

    public func log(_ level: MCPBridgeLogLevel, _ message: String) {
        for logger in loggers {
            logger.log(level, message)
        }
    }
}
