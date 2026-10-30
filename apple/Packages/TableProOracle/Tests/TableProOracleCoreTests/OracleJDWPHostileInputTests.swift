import Foundation
@testable import TableProOracleCore
import Testing

// Anything that connects to the listener, or a compromised server, chooses these bytes. Each malformed input must be a
// thrown error that ends the session, never a trap or an allocation sized by the peer.
struct OracleJDWPHostileInputTests {
    private let sizes = OracleJDWPIDSizes.oracle

    private func compositeBody(policy: UInt8 = 2, count: Int32, rest: Data = Data()) -> Data {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.u8(policy)
        writer.i32(count)
        return writer.data + rest
    }

    @Test func testANegativeEventCountThrows() {
        #expect(throws: OracleJDWPError.malformedPacket) {
            try OracleJDWPEventSet.decode(compositeBody(count: -1), sizes: sizes)
        }
    }

    @Test func testAnEventCountTheBytesCannotHoldThrows() {
        #expect(throws: OracleJDWPError.malformedPacket) {
            try OracleJDWPEventSet.decode(compositeBody(count: Int32.max), sizes: sizes)
        }
        // Two events claimed, one event's bytes sent.
        var event = OracleJDWPWriter(sizes: sizes)
        event.u8(OracleJDWPEventKind.vmStart.rawValue)
        event.i32(0)
        event.id(1, .object)
        #expect(throws: OracleJDWPError.self) {
            try OracleJDWPEventSet.decode(compositeBody(count: 2, rest: event.data), sizes: sizes)
        }
    }

    @Test func testListCountsAreBoundedByTheBytesLeft() {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.i32(Int32.max)
        #expect(throws: OracleJDWPError.malformedPacket) { try OracleJDWPMethod.decodeList(writer.data, sizes: sizes) }
        #expect(throws: OracleJDWPError.malformedPacket) { try OracleJDWPField.decodeList(writer.data, sizes: sizes) }
        var lines = OracleJDWPWriter(sizes: sizes)
        lines.i64(1)
        lines.i64(2)
        lines.i32(-5)
        #expect(throws: OracleJDWPError.malformedPacket) { try OracleJDWPLineTable.decode(lines.data, sizes: sizes) }
        var reader = OracleJDWPReader(Data([0xFF, 0xFF, 0xFF, 0xFF]), sizes: sizes)
        #expect(throws: OracleJDWPError.malformedPacket) { try reader.count(minimumSize: 1) }
    }

    @Test func testAVariableWhoseScopeOverflowsThrows() {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.i32(0)
        writer.i32(1)
        writer.i64(Int64.max)
        writer.string("X")
        writer.string("L$Oracle/Builtin/NUMBER;")
        writer.i32(5)
        writer.i32(0)
        #expect(throws: OracleJDWPError.malformedPacket) { try OracleJDWPVariable.decodeTable(writer.data, sizes: sizes) }
    }

    @Test func testScopeArithmeticNeverTraps() {
        let variable = OracleJDWPVariable(codeIndex: Int64.max - 1, name: "X", signature: "", length: Int.max, slot: 0, isArgument: false)
        #expect(variable.isVisible(at: Int64.max))
        #expect(!variable.isVisible(at: 0))
    }

    @Test func testIDSizesOutsideOneToEightAreRejected() {
        #expect(throws: OracleJDWPError.malformedPacket) {
            try OracleJDWPIDSizes.validated(field: 4, method: 4, object: 0x7FFF_FFFF, referenceType: 4, frame: 8)
        }
        #expect(throws: OracleJDWPError.malformedPacket) {
            try OracleJDWPIDSizes.validated(field: 0, method: 4, object: 4, referenceType: 4, frame: 8)
        }
        #expect(throws: OracleJDWPError.malformedPacket) {
            try OracleJDWPIDSizes.validated(field: 4, method: 4, object: 4, referenceType: 4, frame: -8)
        }
        #expect((try? OracleJDWPIDSizes.validated(field: 4, method: 4, object: 4, referenceType: 4, frame: 8)) == .oracle)
    }

    @Test func testAFrameLongerThanTheCapThrowsBeforeItIsBuffered() {
        var header = Data()
        withUnsafeBytes(of: UInt32(OracleJDWPPacket.maximumLength + 1).bigEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: [0, 0, 0, 1, 0, 64, 100])
        var buffer = OracleJDWPFrameBuffer()
        buffer.append(header)
        #expect(throws: OracleJDWPError.malformedPacket) { try buffer.nextPacket() }
        var short = Data([0, 0, 0, 5, 0, 0, 0, 1, 0, 1, 1])
        short.append(0)
        #expect(throws: OracleJDWPError.malformedPacket) { try OracleJDWPPacket.decode(from: short) }
    }

    @Test func testAnIDWiderThanEightBytesIsNeverRead() {
        let wide = OracleJDWPIDSizes(field: 4, method: 4, object: 9, referenceType: 4, frame: 8)
        var reader = OracleJDWPReader(Data(repeating: 0, count: 16), sizes: wide)
        #expect(throws: OracleJDWPError.malformedPacket) { try reader.id(.object) }
        var writer = OracleJDWPWriter(sizes: OracleJDWPIDSizes(field: 4, method: 4, object: 0x7FFF_FFFF, referenceType: 4, frame: 8))
        writer.id(1, .object)
        #expect(writer.data.count == 8)
    }

    // A malformed frame closes the connection, which is what ends the target, instead of leaving it suspended.
    @Test func testAMalformedFrameClosesTheConnection() async throws {
        let transport = ScriptedTransport(chunks: [OracleJDWPPacket.handshake, Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1, 0, 64, 100])])
        let connection = OracleJDWPConnection(transport: transport)
        try await connection.handshake()
        var commands = connection.commands.makeAsyncIterator()
        #expect(await commands.next() == nil)
        #expect(await connection.closed)
        #expect(transport.isClosed)
    }

    @Test func testPayloadLengthsCannotOverflow() {
        #expect(throws: OracleDebugPayload.ParseError.self) { try OracleDebugPayload.parse("99999999999999999999:x") }
        #expect(throws: OracleDebugPayload.ParseError.self) { try OracleDebugPayload.parse("999999999:x") }
    }

    @Test func testALineMapClaimingHugeLinesReadsOnlyItsBytes() {
        #expect(OracleDBMSDebugStatements.executableLines(hexMap: "FE", maxLine: Int.max) == [1, 2, 3, 4, 5, 6, 7])
        #expect(OracleDBMSDebugStatements.executableLines(hexMap: "", maxLine: 500).isEmpty)
        #expect(OracleDBMSDebugStatements.executableLines(hexMap: "FF", maxLine: -3).isEmpty)
    }
}

private final class ScriptedTransport: OracleJDWPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var closed = false

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    var isClosed: Bool { lock.withLock { closed } }

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data? {
        lock.withLock { chunks.isEmpty ? nil : chunks.removeFirst() }
    }

    func close() {
        lock.withLock { closed = true }
    }
}
