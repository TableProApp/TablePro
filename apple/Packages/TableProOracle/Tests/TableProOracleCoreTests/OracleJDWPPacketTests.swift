import Foundation
@testable import TableProOracleCore
import Testing

struct OracleJDWPPacketTests {
    private let sizes = OracleJDWPIDSizes.oracle

    @Test func testIDSizesCommandEncodesAsRecorded() {
        let packet = OracleJDWPPacket.command(id: 1, commandSet: 1, command: 7, data: Data())
        #expect(packet.encoded == OracleJDWPRecording.bytes("0000000b00000001000107"))
        #expect(packet.encoded == OracleJDWPRecording.idSizesCommand)
    }

    @Test func testReplyAndCommandRoundTrip() throws {
        let reply = OracleJDWPPacket.reply(id: 7, errorCode: 35, data: Data([1, 2, 3]))
        let command = OracleJDWPPacket.command(id: 9, commandSet: 64, command: 100, data: Data([4]))
        for packet in [reply, command] {
            let decoded = try #require(try OracleJDWPPacket.decode(from: packet.encoded))
            #expect(decoded.packet == packet)
            #expect(decoded.length == packet.encoded.count)
        }
    }

    @Test func testIDSizesReplyDecodesOraclesSizes() throws {
        let decoded = try #require(try OracleJDWPPacket.decode(from: OracleJDWPRecording.idSizesReply))
        guard case let .reply(id, errorCode, data) = decoded.packet else {
            Issue.record("expected a reply")
            return
        }
        #expect(id == 1)
        #expect(errorCode == 0)
        var reader = OracleJDWPReader(data, sizes: sizes)
        let read = try (0..<5).map { _ in try reader.i32() }
        #expect(read == [4, 4, 4, 4, 8])
    }

    @Test func testAPartialPacketWaitsForTheRest() throws {
        var buffer = OracleJDWPFrameBuffer()
        let whole = OracleJDWPRecording.vmStartEvent + OracleJDWPRecording.idSizesReply
        buffer.append(whole.prefix(20))
        #expect(try buffer.nextPacket() == nil)
        buffer.append(whole.dropFirst(20))
        let first = try #require(try buffer.nextPacket())
        let second = try #require(try buffer.nextPacket())
        #expect(try buffer.nextPacket() == nil)
        guard case .command(_, 64, 100, _) = first, case .reply(1, 0, _) = second else {
            Issue.record("expected the event, then the reply")
            return
        }
    }

    // Oracle sends VM_START before it answers IDSizes, with a 4-byte thread id.
    @Test func testRecordedEventsDecode() throws {
        func events(_ data: Data) throws -> [OracleJDWPEvent] {
            let decoded = try #require(try OracleJDWPPacket.decode(from: data))
            guard case let .command(_, 64, 100, body) = decoded.packet else { return [] }
            return try OracleJDWPEventSet.decode(body, sizes: sizes).events
        }
        #expect(try events(OracleJDWPRecording.vmStartEvent) == [.vmStart(thread: 1)])
        #expect(try events(OracleJDWPRecording.classPrepareEvent) == [
            .classPrepare(requestID: 1, thread: 1, typeID: 2, signature: "L$Oracle/PackageBody/PROBE/PKG_CALC;")
        ])
        #expect(try events(OracleJDWPRecording.breakpointEvent) == [
            .breakpoint(requestID: 2, thread: 1, location: OracleJDWPLocation(classID: 2, methodID: 4, index: 6))
        ])
    }

    @Test func testRequestsEncodeAsRecorded() {
        let classPrepare = OracleJDWPRequest.classPrepare(matching: "$Oracle/PackageBody/PROBE/PKG_CALC", sizes: sizes)
        #expect(OracleJDWPPacket.command(id: 3, commandSet: 15, command: 1, data: classPrepare).encoded
            == OracleJDWPRecording.classPrepareCommand)
        let breakpoint = OracleJDWPRequest.breakpoint(
            at: OracleJDWPLocation(classID: 2, methodID: 4, index: 6),
            sizes: sizes
        )
        #expect(OracleJDWPPacket.command(id: 7, commandSet: 15, command: 1, data: breakpoint).encoded
            == OracleJDWPRecording.breakpointCommand)
        var frames = OracleJDWPWriter(sizes: sizes)
        frames.id(1, .object)
        frames.i32(0)
        frames.i32(-1)
        #expect(OracleJDWPPacket.command(id: 9, commandSet: 11, command: 6, data: frames.data).encoded
            == OracleJDWPRecording.framesCommand)
    }

    @Test func testFramesReplyReadsThreeFramesWithEightByteIDs() throws {
        let decoded = try #require(try OracleJDWPPacket.decode(from: OracleJDWPRecording.framesReply))
        guard case let .reply(_, _, data) = decoded.packet else {
            Issue.record("expected a reply")
            return
        }
        var reader = OracleJDWPReader(data, sizes: sizes)
        #expect(try reader.i32() == 3)
        #expect(try reader.id(.frame) == 0x1_0000_0001)
        #expect(try reader.location() == OracleJDWPLocation(classID: 2, methodID: 4, index: 6))
        #expect(try reader.id(.frame) == 0x1_0000_0002)
        #expect(try reader.location() == OracleJDWPLocation(classID: 2, methodID: 5, index: 14))
    }

    @Test func testTaggedValuesReadEachWidth() throws {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.u8(UInt8(ascii: "Z"))
        writer.u8(1)
        writer.u8(UInt8(ascii: "I"))
        writer.i32(30)
        writer.u8(UInt8(ascii: "s"))
        writer.id(0, .object)
        writer.u8(UInt8(ascii: "L"))
        writer.id(72, .object)
        var reader = OracleJDWPReader(writer.data, sizes: sizes)
        #expect(try reader.taggedValue() == .primitive(tag: UInt8(ascii: "Z"), bits: 1))
        #expect(try reader.taggedValue() == .primitive(tag: UInt8(ascii: "I"), bits: 30))
        #expect(try reader.taggedValue() == .object(tag: OracleJDWPValue.stringTag, id: 0))
        #expect(try reader.taggedValue().objectID == 72)
        #expect(reader.isAtEnd)
    }

    @Test func testATruncatedBodyThrows() {
        var reader = OracleJDWPReader(Data([0, 0, 0, 9, 65]), sizes: sizes)
        #expect(throws: OracleJDWPError.truncated) { try reader.string() }
    }
}
