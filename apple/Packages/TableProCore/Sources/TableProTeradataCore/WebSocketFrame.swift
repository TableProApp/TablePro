import CryptoKit
import Foundation
import TableProWireIO

enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WebSocketFrame {
    let opcode: WebSocketOpcode
    let payload: [UInt8]

    static let maxPayload = 64 * 1_024 * 1_024
    static let maxHeaderLength = 14

    static func acceptKey(for clientKey: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((clientKey + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    static func encodeBinary(_ payload: [UInt8]) -> [UInt8] {
        encode(opcode: .binary, payload: payload)
    }

    static func encode(opcode: WebSocketOpcode, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode.rawValue]
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)
        return frame
    }

    static func decode(_ buffer: inout ByteQueue) throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[0]
        let second = buffer[1]
        let masked = second & 0x80 != 0
        var declaredLength = UInt64(second & 0x7F)
        var offset = 2

        if declaredLength == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            declaredLength = UInt64(buffer[offset]) << 8 | UInt64(buffer[offset + 1])
            offset += 2
        } else if declaredLength == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            declaredLength = 0
            for index in offset..<(offset + 8) { declaredLength = declaredLength << 8 | UInt64(buffer[index]) }
            offset += 8
        }
        guard let length = Int(exactly: declaredLength), length <= maxPayload else {
            throw TeradataWireError.malformed("WebSocket frame length \(declaredLength)")
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = (offset..<(offset + 4)).map { buffer[$0] }
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }

        buffer.removeFirst(offset)
        var payload = buffer.removeFirst(length)
        if masked {
            for index in payload.indices { payload[index] ^= maskKey[index % 4] }
        }

        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw TeradataWireError.malformed("WebSocket opcode \(first & 0x0F)")
        }
        return WebSocketFrame(opcode: opcode, payload: payload)
    }
}
