import Darwin
import Foundation
import os

public struct MCPHandshakePayload: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public let version: Int
    public let port: Int
    public let token: String
    public let pid: Int32
    public let instanceId: String
    public let protocolVersion: String
    public let expiresAt: Date

    public init(
        port: Int,
        token: String,
        pid: Int32,
        instanceId: String,
        protocolVersion: String,
        expiresAt: Date
    ) {
        self.version = Self.currentVersion
        self.port = port
        self.token = token
        self.pid = pid
        self.instanceId = instanceId
        self.protocolVersion = protocolVersion
        self.expiresAt = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970.rounded(.down))
    }

    public func isExpired(now: Date) -> Bool {
        now >= expiresAt
    }

    public var endpoint: URL? {
        URL(string: "http://127.0.0.1:\(port)/mcp")
    }
}

public enum MCPHandshakeCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum MCPHandshakeLocation {
    public static let fileName = "mcp-handshake.json"
    public static let sandboxEnvironmentVariable = "TABLEPRO_UI_TEST_SANDBOX"

    public static func file(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func supportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let sandbox = environment[sandboxEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let sandbox, !sandbox.isEmpty {
            return URL(fileURLWithPath: sandbox, isDirectory: true)
                .appendingPathComponent("TablePro", isDirectory: true)
        }
        // swiftlint:disable:next storage_environment_directory
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("TablePro", isDirectory: true)
    }
}

public enum MCPHandshakeTrustFailure: Error, LocalizedError, Equatable {
    case missing
    case notARegularFile
    case foreignOwner
    case worldReadable
    case unreadableDirectory
    case malformed
    case unsupportedVersion(Int)
    case expired
    case hostNotRunning(pid: Int32)
    case hostIsNotTablePro(path: String)

    public var errorDescription: String? {
        switch self {
        case .missing:
            return "Handshake file not found"
        case .notARegularFile:
            return "Handshake path is not a regular file"
        case .foreignOwner:
            return "Handshake file belongs to another user"
        case .worldReadable:
            return "Handshake file is readable by other users"
        case .unreadableDirectory:
            return "Handshake directory is writable by other users"
        case .malformed:
            return "Handshake file is malformed"
        case .unsupportedVersion(let version):
            return "Handshake file version \(version) is not supported"
        case .expired:
            return "Handshake credential expired"
        case .hostNotRunning(let pid):
            return "TablePro process \(pid) is not running"
        case .hostIsNotTablePro(let path):
            return "Handshake points at a process that is not TablePro: \(path)"
        }
    }
}

public enum MCPHandshakeTrust {
    public static func load(
        at url: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> MCPHandshakePayload {
        try verifyDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        try verifyFileMode(url, fileManager: fileManager)

        guard let data = try? Data(contentsOf: url) else {
            throw MCPHandshakeTrustFailure.missing
        }
        guard let payload = try? MCPHandshakeCoding.decoder().decode(MCPHandshakePayload.self, from: data) else {
            throw MCPHandshakeTrustFailure.malformed
        }
        guard payload.version == MCPHandshakePayload.currentVersion else {
            throw MCPHandshakeTrustFailure.unsupportedVersion(payload.version)
        }
        guard !payload.token.isEmpty,
              !payload.instanceId.isEmpty,
              (1...65_535).contains(payload.port) else {
            throw MCPHandshakeTrustFailure.malformed
        }
        guard !payload.isExpired(now: now) else {
            throw MCPHandshakeTrustFailure.expired
        }
        guard isRunning(pid: payload.pid) else {
            throw MCPHandshakeTrustFailure.hostNotRunning(pid: payload.pid)
        }
        try verifyHostExecutable(pid: payload.pid)
        return payload
    }

    public static func isRunning(pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    public static func executablePath(forPid pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer[0..<Int(length)], encoding: .utf8)
    }

    public static func appBundleRoot(forExecutable path: String) -> String? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" {
                return url.standardizedFileURL.path
            }
        }
        return nil
    }

    private static func verifyFileMode(_ url: URL, fileManager: FileManager) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw MCPHandshakeTrustFailure.missing
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw MCPHandshakeTrustFailure.notARegularFile
        }
        guard let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw MCPHandshakeTrustFailure.foreignOwner
        }
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.int32Value & 0o077 == 0 else {
            throw MCPHandshakeTrustFailure.worldReadable
        }
    }

    private static func verifyDirectory(_ url: URL, fileManager: FileManager) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw MCPHandshakeTrustFailure.missing
        }
        guard let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw MCPHandshakeTrustFailure.foreignOwner
        }
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.int32Value & 0o022 == 0 else {
            throw MCPHandshakeTrustFailure.unreadableDirectory
        }
    }

    private static func verifyHostExecutable(pid: Int32) throws {
        guard let hostPath = executablePath(forPid: pid) else {
            throw MCPHandshakeTrustFailure.hostIsNotTablePro(path: "unknown")
        }

        let ownPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? ProcessInfo.processInfo.arguments.first
        if let ownRoot = ownPath.flatMap({ appBundleRoot(forExecutable: $0) }), hostPath.hasPrefix(ownRoot + "/") {
            return
        }

        guard URL(fileURLWithPath: hostPath).lastPathComponent == "TablePro" else {
            throw MCPHandshakeTrustFailure.hostIsNotTablePro(path: hostPath)
        }
    }
}

public final class MCPServerInstanceIdentity: Sendable {
    public static let shared = MCPServerInstanceIdentity()
    public static let metaKey = "app.tablepro/instanceId"

    private let identifier = OSAllocatedUnfairLock(initialState: "")

    private init() {}

    public var current: String {
        identifier.withLock { $0 }
    }

    @discardableResult
    public func begin() -> String {
        let value = UUID().uuidString
        identifier.withLock { $0 = value }
        return value
    }

    public func end() {
        identifier.withLock { $0 = "" }
    }
}

@MainActor
internal final class MCPHandshakeFile {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Handshake")

    private let directory: URL
    private let fileManager: FileManager

    internal init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    internal var url: URL {
        MCPHandshakeLocation.file(in: directory)
    }

    internal func write(_ payload: MCPHandshakePayload) {
        do {
            try prepareDirectory()
            let data = try MCPHandshakeCoding.encoder().encode(payload)
            let staging = directory.appendingPathComponent(
                ".\(MCPHandshakeLocation.fileName).\(UUID().uuidString)",
                isDirectory: false
            )
            guard fileManager.createFile(
                atPath: staging.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                Self.logger.error("Could not stage the MCP handshake file")
                return
            }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: staging, to: url)
            Self.logger.info("Wrote the MCP handshake file at \(self.url.path, privacy: .public)")
        } catch {
            Self.logger.error("Failed to write the MCP handshake file: \(error.localizedDescription, privacy: .public)")
        }
    }

    internal func removeIfWrittenByThisProcess(instanceId: String) {
        guard let payload = readWithoutTrustChecks() else { return }
        guard payload.pid == ProcessInfo.processInfo.processIdentifier,
              payload.instanceId == instanceId else {
            Self.logger.info("Left an MCP handshake file that belongs to another instance in place")
            return
        }
        remove()
    }

    internal func removeIfAbandoned() {
        guard let payload = readWithoutTrustChecks() else { return }
        let isOwnProcess = payload.pid == ProcessInfo.processInfo.processIdentifier
        let isLive = MCPHandshakeTrust.isRunning(pid: payload.pid)
        guard isOwnProcess || !isLive || payload.isExpired(now: Date()) else { return }
        remove()
        Self.logger.info("Removed an abandoned MCP handshake from PID \(payload.pid, privacy: .public)")
    }

    private func remove() {
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Self.logger.error("Failed to delete the handshake file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readWithoutTrustChecks() -> MCPHandshakePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MCPHandshakeCoding.decoder().decode(MCPHandshakePayload.self, from: data)
    }

    private func prepareDirectory() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
