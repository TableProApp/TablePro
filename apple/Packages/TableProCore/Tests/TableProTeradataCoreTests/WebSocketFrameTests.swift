@testable import TableProTeradataCore
import TableProWireIO
import Testing

struct WebSocketFrameTests {
    private static func queue(_ bytes: [UInt8]) -> ByteQueue {
        var queue = ByteQueue()
        queue.append(contentsOf: bytes)
        return queue
    }

    @Test("A 64-bit frame length with the top bit set is refused instead of crashing")
    func topBitLengthIsRefused() {
        var topBit = Self.queue([0x82, 0x7F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(throws: TeradataWireError.self) { try WebSocketFrame.decode(&topBit) }
        var intMax = Self.queue([0x82, 0x7F, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: TeradataWireError.self) { try WebSocketFrame.decode(&intMax) }
    }

    @Test("Frames of each length form and a masked frame decode to their payloads, and a partial frame waits")
    func validFramesDecode() throws {
        let payloads = [5, 300, 70_000].map { [UInt8](repeating: UInt8(truncatingIfNeeded: $0), count: $0) }
        var buffer = ByteQueue()
        for payload in payloads {
            buffer.append(contentsOf: WebSocketFrame.encodeBinary(payload))
        }
        // A ping masked with 11 22 33 44 whose payload is "abc".
        buffer.append(contentsOf: [0x89, 0x83, 0x11, 0x22, 0x33, 0x44, 0x70, 0x40, 0x50])
        buffer.append(contentsOf: [0x82, 0x7E, 0x01])

        for payload in payloads {
            let frame = try WebSocketFrame.decode(&buffer)
            #expect(frame?.opcode == WebSocketOpcode.binary)
            #expect(frame?.payload == payload)
        }
        let ping = try WebSocketFrame.decode(&buffer)
        #expect(ping?.opcode == WebSocketOpcode.ping)
        #expect(ping?.payload == Array("abc".utf8))
        let partial = try WebSocketFrame.decode(&buffer)
        #expect(partial == nil)
        #expect(buffer.count == 3)
    }

    // Removing each frame from the front of an array moves the rest of the buffer: minutes for this input.
    @Test("Eight megabytes of two-byte frames drain in time linear in their size", .timeLimit(.minutes(1)))
    func manySmallFramesDrainLinearly() throws {
        let frameCount = 1 << 22
        var bytes = [UInt8](repeating: 0x00, count: frameCount * 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            bytes[index] = 0x8A
        }
        var buffer = Self.queue(bytes)
        var drained = 0
        while try WebSocketFrame.decode(&buffer) != nil {
            drained += 1
        }
        #expect(drained == frameCount)
        #expect(buffer.isEmpty)
    }
}
