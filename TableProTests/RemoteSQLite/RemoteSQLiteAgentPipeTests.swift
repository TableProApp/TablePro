//
//  RemoteSQLiteAgentPipeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Runs the SQLite agent that ships in the app against a real database, driven with the local
/// `python3` over pipes. It proves the embedded program and the plugin's codec agree on the wire,
/// that typed values and declared types come back the way the local driver reads them, and that the
/// server-side safety rules hold, without needing SSH.
struct RemoteSQLiteAgentPipeTests {
    private static var python3Path: String? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where
            FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    static var hasPython3: Bool { python3Path != nil }

    // MARK: - Harness

    private final class Agent {
        private let process = Process()
        private let toAgent = Pipe()
        private let fromAgent = Pipe()
        private var reader = SQLiteAgentFrameReader()

        init(pythonPath: String) throws {
            let encoded = Data(RemoteSQLiteAgentSource.python.utf8).base64EncodedString()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-I", "-S", "-c", "import base64,sys;exec(base64.b64decode(sys.argv[1]))", encoded]
            process.standardInput = toAgent
            process.standardOutput = fromAgent
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func send(_ request: SQLiteAgentRequest) {
            toAgent.fileHandleForWriting.write(SQLiteAgentFrameEncoder.encode(request))
        }

        func nextReply() throws -> SQLiteAgentReply {
            while true {
                if let reply = try reader.nextReply() { return reply }
                let chunk = fromAgent.fileHandleForReading.availableData
                if chunk.isEmpty { throw AgentError.closed }
                reader.append(chunk)
            }
        }

        /// Reads a full EXEC response: header, then rows, then done or error.
        func runExecute(_ sql: String, parameters: [SQLiteAgentValue] = []) throws -> ExecuteResult {
            send(.execute(sql: sql, parameters: parameters, rowCap: 0))
            var columns: [SQLiteAgentColumn] = []
            var rows: [[SQLiteAgentValue]] = []
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
                case .error(_, let message):
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

        enum AgentError: Error { case closed, unexpected }
        enum ExecuteResult {
            case ok(columns: [SQLiteAgentColumn], rows: [[SQLiteAgentValue]], changes: Int64, truncated: Bool)
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
        agent.send(.hello(protocolVersion: 1, path: path, busyTimeoutMilliseconds: 2000))
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
        agent.send(.hello(protocolVersion: 1, path: path, busyTimeoutMilliseconds: 2000))
        guard case .failure(let failure) = try agent.nextReply() else {
            Issue.record("expected a failure for a missing file")
            return
        }
        #expect(failure.code == SQLiteAgentFailure.openFailed)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
