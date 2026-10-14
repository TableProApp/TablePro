//
//  RemoteSQLiteAgentPipeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Runs the SQLite agent that ships in the app against a real database, driven with the local
/// `python3` over pipes. It proves the embedded program speaks the wire layout below, that typed values
/// and declared types come back the way the local driver reads them, and that the server-side safety
/// rules hold, without needing SSH. SQLiteDriverTests' SQLiteAgentWireFixtureTests holds the plugin's
/// codec to the same layout.
struct RemoteSQLiteAgentPipeTests {
    private static var python3Path: String? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where
            FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static var hasPython3: Bool { python3Path != nil }

    // MARK: - Wire

    fileprivate enum Value: Equatable {
        case null
        case text(Data)
        case blob(Data)
    }

    fileprivate struct Column: Equatable {
        let name: String
        let declaredType: String?
    }

    fileprivate enum Reply {
        case ready
        case failure(code: UInt32, message: String)
        case header([Column])
        case rows(columnCount: Int, values: [Value])
        case done(changes: Int64, truncated: Bool)
        case error(message: String)
    }

    /// A frame is a big-endian length, an opcode, then the payload. Text is a length and its bytes.
    private enum Wire {
        static func uint32(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }

        static func bytes(_ data: Data) -> [UInt8] {
            uint32(UInt32(data.count)) + Array(data)
        }

        static func string(_ text: String) -> [UInt8] {
            bytes(Data(text.utf8))
        }

        static func value(_ value: Value) -> [UInt8] {
            switch value {
            case .null: return [0]
            case .text(let data): return [1] + bytes(data)
            case .blob(let data): return [2] + bytes(data)
            }
        }

        static func frame(_ opcode: UInt8, _ payload: [UInt8]) -> Data {
            Data(uint32(UInt32(payload.count + 1)) + [opcode] + payload)
        }

        static func hello(path: String, busyTimeoutMilliseconds: UInt32) -> Data {
            frame(0x01, uint32(1) + string(path) + uint32(busyTimeoutMilliseconds))
        }

        static func execute(_ sql: String, parameters: [Value]) -> Data {
            frame(0x02, string(sql) + uint32(UInt32(parameters.count)) + parameters.flatMap(value) + uint32(0))
        }
    }

    private struct Cursor {
        let bytes: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, bytes.count - offset >= count else { throw Agent.AgentError.truncated }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func uint8() throws -> UInt8 {
            try take(1)[0]
        }

        mutating func uint32() throws -> UInt32 {
            try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        mutating func int64() throws -> Int64 {
            Int64(bitPattern: try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        }

        mutating func data() throws -> Data {
            let count = Int(try uint32())
            return Data(try take(count))
        }

        mutating func string() throws -> String {
            guard let text = String(data: try data(), encoding: .utf8) else {
                throw Agent.AgentError.unexpected
            }
            return text
        }

        mutating func value() throws -> Value {
            switch try uint8() {
            case 0: return .null
            case 1: return .text(try data())
            case 2: return .blob(try data())
            default: throw Agent.AgentError.unexpected
            }
        }

        mutating func reply(opcode: UInt8) throws -> Reply {
            switch opcode {
            case 0x81:
                _ = try uint32()
                _ = try string()
                _ = try string()
                return .ready
            case 0x82:
                return .failure(code: try uint32(), message: try string())
            case 0x83:
                let count = Int(try uint32())
                return .header(try (0..<count).map { _ in
                    let name = try string()
                    return Column(name: name, declaredType: try uint8() == 1 ? try string() : nil)
                })
            case 0x84:
                let columnCount = Int(try uint32())
                let rowCount = Int(try uint32())
                return .rows(columnCount: columnCount, values: try (0..<(columnCount * rowCount)).map { _ in try value() })
            case 0x85:
                return .done(changes: try int64(), truncated: try uint8() == 1)
            case 0x86:
                _ = try uint32()
                return .error(message: try string())
            default:
                throw Agent.AgentError.unexpected
            }
        }
    }

    // MARK: - Harness

    private final class Agent {
        private let process = Process()
        private let toAgent = Pipe()
        private let fromAgent = Pipe()
        private var buffer: [UInt8] = []

        init(pythonPath: String) throws {
            let encoded = Data(RemoteSQLiteAgentSource.python.utf8).base64EncodedString()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-I", "-S", "-c", "import base64,sys;exec(base64.b64decode(sys.argv[1]))", encoded]
            process.standardInput = toAgent
            process.standardOutput = fromAgent
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func send(_ frame: Data) {
            toAgent.fileHandleForWriting.write(frame)
        }

        func nextReply() throws -> Reply {
            while true {
                if let reply = try takeReply() { return reply }
                let chunk = fromAgent.fileHandleForReading.availableData
                if chunk.isEmpty { throw AgentError.closed }
                buffer.append(contentsOf: chunk)
            }
        }

        private func takeReply() throws -> Reply? {
            guard buffer.count >= 4 else { return nil }
            var header = Cursor(Array(buffer[0..<4]))
            let length = Int(try header.uint32())
            guard length > 0 else { throw AgentError.unexpected }
            guard buffer.count >= 4 + length else { return nil }
            var payload = Cursor(Array(buffer[5..<(4 + length)]))
            let reply = try payload.reply(opcode: buffer[4])
            buffer.removeFirst(4 + length)
            guard payload.isAtEnd else { throw AgentError.unexpected }
            return reply
        }

        /// Reads a full EXEC response: header, then rows, then done or error.
        func runExecute(_ sql: String, parameters: [Value] = []) throws -> ExecuteResult {
            send(Wire.execute(sql, parameters: parameters))
            var columns: [Column] = []
            var rows: [[Value]] = []
            while true {
                switch try nextReply() {
                case .header(let cols): columns = cols
                case .rows(let count, let values):
                    var index = 0
                    while index < values.count {
                        rows.append(Array(values[index..<(index + count)]))
                        index += count
                    }
                case .done(let changes, let truncated):
                    return .ok(columns: columns, rows: rows, changes: changes, truncated: truncated)
                case .error(let message):
                    return .error(message)
                default:
                    throw AgentError.unexpected
                }
            }
        }

        func close() {
            toAgent.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }

        enum AgentError: Error { case closed, truncated, unexpected }
        enum ExecuteResult {
            case ok(columns: [Column], rows: [[Value]], changes: Int64, truncated: Bool)
            case error(String)
        }
    }

    private func withEmptyDatabase(_ body: (String, Agent) throws -> Void) throws {
        let python = try #require(Self.python3Path)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-\(UUID().uuidString).db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let agent = try Agent(pythonPath: python)
        defer { agent.close() }
        agent.send(Wire.hello(path: path, busyTimeoutMilliseconds: 2000))
        guard case .ready = try agent.nextReply() else {
            Issue.record("agent did not report ready")
            return
        }
        try body(path, agent)
    }

    // MARK: - Tests

    @Test(.enabled(if: RemoteSQLiteAgentPipeTests.hasPython3))
    func typedValuesAndDeclaredTypesMatchTheLocalDriver() throws {
        try withEmptyDatabase { _, agent in
            _ = try agent.runExecute("CREATE TABLE t(a INTEGER, b VARCHAR(9), c BLOB, d REAL)")
            _ = try agent.runExecute(
                "INSERT INTO t VALUES(?, ?, ?, ?)",
                parameters: [.text(Data("9223372036854775807".utf8)), .text(Data("x".utf8)), .blob(Data([0x00, 0xFF])), .text(Data("0.1".utf8))]
            )
            guard case .ok(let columns, let rows, _, _) = try agent.runExecute("SELECT a, b AS bee, c, d, a + 1 AS expr FROM t") else {
                Issue.record("select failed")
                return
            }
            #expect(columns.map(\.name) == ["a", "bee", "c", "d", "expr"])
            #expect(columns.map { $0.declaredType } == ["INTEGER", "VARCHAR(9)", "BLOB", "REAL", nil])
            #expect(rows.count == 1)
            #expect(rows[0][0] == .text(Data("9223372036854775807".utf8)))
            #expect(rows[0][2] == .blob(Data([0x00, 0xFF])))
        }
    }

    @Test(.enabled(if: RemoteSQLiteAgentPipeTests.hasPython3))
    func insertReportsRowCount() throws {
        try withEmptyDatabase { _, agent in
            _ = try agent.runExecute("CREATE TABLE t(a INTEGER)")
            guard case .ok(_, _, let changes, _) = try agent.runExecute("INSERT INTO t VALUES(1)") else {
                Issue.record("insert failed")
                return
            }
            #expect(changes == 1)
        }
    }

    @Test(.enabled(if: RemoteSQLiteAgentPipeTests.hasPython3))
    func statementThatWritesNothingReportsNoRowsAfterAWrite() throws {
        try withEmptyDatabase { _, agent in
            _ = try agent.runExecute("CREATE TABLE t(a INTEGER)")
            _ = try agent.runExecute("INSERT INTO t VALUES(1), (2), (3)")
            guard case .ok(_, _, let createChanges, _) = try agent.runExecute("CREATE TABLE u(b INTEGER)"),
                  case .ok(_, _, let deleteChanges, _) = try agent.runExecute("DELETE FROM t WHERE a > 9") else {
                Issue.record("statement failed")
                return
            }
            #expect(createChanges == 0)
            #expect(deleteChanges == 0)
        }
    }

    @Test(.enabled(if: RemoteSQLiteAgentPipeTests.hasPython3))
    func fts3TokenizerIsDeniedByTheAuthorizer() throws {
        try withEmptyDatabase { _, agent in
            guard case .error(let message) = try agent.runExecute("SELECT fts3_tokenizer('evil', x'4141414141414141')") else {
                Issue.record("fts3_tokenizer was not denied")
                return
            }
            #expect(message.contains("not authorized") || message.contains("no such function"))
        }
    }

    @Test(.enabled(if: RemoteSQLiteAgentPipeTests.hasPython3))
    func loadExtensionIsUnavailable() throws {
        try withEmptyDatabase { _, agent in
            guard case .error = try agent.runExecute("SELECT load_extension('x')") else {
                Issue.record("load_extension was not blocked")
                return
            }
        }
    }

    @Test(.enabled(if: RemoteSQLiteAgentPipeTests.hasPython3))
    func openingAMissingFileFailsWithoutCreatingIt() throws {
        let python = try #require(Self.python3Path)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).db").path
        let agent = try Agent(pythonPath: python)
        defer { agent.close() }
        agent.send(Wire.hello(path: path, busyTimeoutMilliseconds: 2000))
        guard case .failure(let code, _) = try agent.nextReply() else {
            Issue.record("expected a failure for a missing file")
            return
        }
        #expect(code == 4, "the open-failed code")
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
