//
//  SQLiteAgentWireFixtureTests.swift
//  SQLiteDriverTests
//

import Foundation
import Testing

// TableProTests pins the app's side of the remote SQLite wire to these same bytes and values: the constants in
// RemoteSQLiteWireParityTests, and the frame layout RemoteSQLiteAgentPipeTests drives the embedded agent with.
struct SQLiteAgentWireFixtureTests {
    @Test("The wire constants are the ones the app writes")
    func constantsArePinned() {
        #expect(SQLiteAgentProtocol.backendFieldKey == "sqliteBackend")
        #expect(SQLiteAgentProtocol.agentBackendValue == "agent")
        #expect(SQLiteAgentProtocol.tokenFieldKey == "sqliteAgentToken")
        #expect(SQLiteAgentProtocol.admissionPrefix == "TPRSQL1 ")
        #expect(SQLiteAgentProtocol.noPythonNotice == "TPRSQL:NO_PYTHON")
        #expect(SQLiteAgentProtocol.noPythonNotice.hasPrefix(SQLiteAgentProtocol.launcherNoticePrefix))
        #expect(SQLiteAgentProtocol.admissionPreamble(token: "abc123") == Data("TPRSQL1 abc123\n".utf8))
        #expect(SQLiteAgentFailure.openFailed == 4)
    }

    @Test("A hello is the length, the opcode, the version, the path and the busy timeout")
    func helloFrame() {
        let frame = SQLiteAgentFrameEncoder.encode(
            SQLiteAgentRequest.hello(protocolVersion: 1, path: "/a.db", busyTimeoutMilliseconds: 2_000)
        )
        #expect(frame == Data([0, 0, 0, 18, 0x01, 0, 0, 0, 1, 0, 0, 0, 5] + Array("/a.db".utf8) + [0, 0, 0x07, 0xD0]))
    }

    @Test("An execute carries its SQL, each parameter by tag, and the row cap")
    func executeFrame() {
        let frame = SQLiteAgentFrameEncoder.encode(
            SQLiteAgentRequest.execute(
                sql: "S",
                parameters: [.null, .text(Data("x".utf8)), .blob(Data([0xFF]))],
                rowCap: 0
            )
        )
        let payload: [UInt8] = [0, 0, 0, 1] + Array("S".utf8) + [0, 0, 0, 3]
            + [0] + [1, 0, 0, 0, 1] + Array("x".utf8) + [2, 0, 0, 0, 1, 0xFF] + [0, 0, 0, 0]
        #expect(frame == Data([0, 0, 0, UInt8(payload.count + 1), 0x02] + payload))
    }

    private func reply(_ opcode: UInt8, _ payload: [UInt8]) throws -> SQLiteAgentReply? {
        var reader = SQLiteAgentFrameReader()
        reader.append(Data([0, 0, 0, UInt8(payload.count + 1), opcode] + payload))
        return try reader.nextReply()
    }

    @Test("Each reply the agent writes decodes from its bytes")
    func repliesDecode() throws {
        #expect(try reply(0x81, [0, 0, 0, 1, 0, 0, 0, 1] + Array("3".utf8) + [0, 0, 0, 1] + Array("p".utf8))
            == .ready(protocolVersion: 1, sqliteVersion: "3", pythonVersion: "p"))
        #expect(try reply(0x82, [0, 0, 0, 4, 0, 0, 0, 1] + Array("m".utf8))
            == .failure(SQLiteAgentFailure(code: 4, message: "m")))
        #expect(try reply(0x83, [0, 0, 0, 2, 0, 0, 0, 1] + Array("a".utf8) + [1, 0, 0, 0, 1] + Array("T".utf8)
            + [0, 0, 0, 1] + Array("b".utf8) + [0])
            == .header([SQLiteAgentColumn(name: "a", declaredType: "T"), SQLiteAgentColumn(name: "b", declaredType: nil)]))
        #expect(try reply(0x84, [0, 0, 0, 2, 0, 0, 0, 1, 0, 2, 0, 0, 0, 1, 0xAB])
            == .rows(columnCount: 2, values: [.null, .blob(Data([0xAB]))]))
        #expect(try reply(0x85, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1])
            == .done(changes: -1, truncated: true))
        #expect(try reply(0x86, [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1] + Array("e".utf8))
            == .error(code: -1, message: "e"))
    }

    @Test func agentHelloKeepsTheInjectedAbsoluteBudget() throws {
        let startedAt = ContinuousClock.now
        let sixtySeconds = try #require(SQLiteAgentHelloBudget.forAgent(
            additionalFields: [
                SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue,
                "connectTimeoutMilliseconds": "60000"
            ],
            now: startedAt
        ))
        let tenMinutes = try #require(SQLiteAgentHelloBudget.forAgent(
            additionalFields: [
                SQLiteAgentProtocol.backendFieldKey: SQLiteAgentProtocol.agentBackendValue,
                "connectTimeoutSeconds": "600"
            ],
            now: startedAt
        ))

        #expect(sixtySeconds.remainingMilliseconds(at: startedAt.advanced(by: .seconds(20))) == 40_000)
        #expect(tenMinutes.remainingMilliseconds(at: startedAt) == 600_000)
    }

    @Test func localSQLiteFieldsDoNotCreateAnAgentHelloBudget() {
        let budget = SQLiteAgentHelloBudget.forAgent(
            additionalFields: ["connectTimeoutMilliseconds": "600000"]
        )
        #expect(budget == nil)
    }
}
