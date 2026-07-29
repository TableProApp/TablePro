import Foundation

enum Td2Token {
    static let keyDataOffset = 80

    static let clientInitToken: [UInt8] = HexBytes.decode("""
        01 01 01 00 00 00 00 9D 00 00 00 15 02 00 00 00
        14 00 00 3A 00 00 00 00 00 00 00 00 00 00 00 00
        00 00 00 00 00 00 00 5D 00 00 00 00 00 00 00 00
        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
        E1 5B E2 15 D0 01 02 D3 01 01 D4 01 04 D5 02 00
        80 D5 02 00 C0 D5 02 01 00 E2 03 D1 01 04 E2 03
        D1 01 06 E2 03 D1 01 07 E2 07 D2 01 05 D6 02 08
        00 E2 09 D0 01 02 D3 01 07 D4 01 04 E2 09 D0 01
        02 D3 01 05 D4 01 04 E2 09 D0 01 02 D3 01 08 D4
        01 04 E2 09 D0 01 02 D3 01 09 D4 01 04 06 0D 2B
        06 01 04 01 81 3F 01 87 74 01 01 09 46 08 00 02
        81 00 04 04 04 00 01 00 00 00 1F 01
        """)

    struct ServerParams {
        let peerCapabilities: UInt32
        let verifyDHKey: UInt32
        let prime: [UInt8]
        let generator: [UInt8]
        let serverPublicKey: [UInt8]
        let qopDer: [UInt8]
    }

    static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func parseServerParams(_ token: [UInt8]) throws -> ServerParams {
        guard token.count >= keyDataOffset else { throw TeradataWireError.truncated("server TD2 token") }
        let version = token[0]
        let msgType = token[1]
        guard version == 1 || version == 3 else { throw TeradataWireError.malformed("TD2 version \(version)") }
        guard msgType == 1 || msgType == 2 else { throw TeradataWireError.malformed("TD2 msgType \(msgType)") }
        let peerCapabilities = be32(token, 8)
        guard token[16] >= 6 else { throw TeradataWireError.malformed("TD2 lib version \(token[16])") }
        let nN = Int(be32(token, 20))
        let nG = Int(be32(token, 24))
        let nY = Int(be32(token, 28))
        let verifyDHKey = be32(token, 32)
        let nQ = (peerCapabilities & 4) != 0 ? Int(be32(token, 36)) : 0

        var cursor = keyDataOffset
        func slice(_ length: Int, _ what: String) throws -> [UInt8] {
            guard cursor + length <= token.count else { throw TeradataWireError.truncated("TD2 \(what)") }
            defer { cursor += length }
            return Array(token[cursor..<cursor + length])
        }
        let prime = try slice(nN, "prime")
        let generator = try slice(nG, "generator")
        let serverPublicKey = try slice(nY, "serverPublicKey")
        let qopDer = nQ > 0 ? try slice(nQ, "qopDer") : []

        return ServerParams(
            peerCapabilities: peerCapabilities, verifyDHKey: verifyDHKey,
            prime: prime, generator: generator, serverPublicKey: serverPublicKey, qopDer: qopDer)
    }

    static func qopKeyLengthBytes(_ qopDer: [UInt8]) -> Int? {
        var index = 0
        while index + 4 <= qopDer.count {
            if qopDer[index] == 0xD5, qopDer[index + 1] == 0x02 {
                let bits = Int(qopDer[index + 2]) << 8 | Int(qopDer[index + 3])
                return bits > 0 ? bits / 8 : nil
            }
            index += 1
        }
        return nil
    }

    static func buildResponseToken(clientPublicKey: [UInt8]) -> [UInt8] {
        let length = UInt32(clientPublicKey.count)
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 0x03
        header[1] = 0x01
        header[2] = 0x02
        header[3] = 0x00
        header[4] = UInt8((length >> 24) & 0xFF)
        header[5] = UInt8((length >> 16) & 0xFF)
        header[6] = UInt8((length >> 8) & 0xFF)
        header[7] = UInt8(length & 0xFF)
        header[12] = 0x02
        return header + clientPublicKey
    }
}
