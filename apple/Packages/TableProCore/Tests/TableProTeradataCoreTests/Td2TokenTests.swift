@testable import TableProTeradataCore
import Testing

struct Td2TokenTests {
    private static func serverToken(prime: [UInt8], generator: [UInt8] = [0x02], publicKey: [UInt8] = [0x01]) -> [UInt8] {
        var token = [UInt8](repeating: 0, count: Td2Token.keyDataOffset)
        token[0] = 1
        token[1] = 1
        token[16] = 6
        for (offset, length) in [(20, prime.count), (24, generator.count), (28, publicKey.count)] {
            for index in 0..<4 {
                token[offset + index] = UInt8(truncatingIfNeeded: length >> (8 * (3 - index)))
            }
        }
        return token + prime + generator + publicKey
    }

    @Test("An empty, zero or even prime is refused before it reaches the modular arithmetic")
    func unusablePrimeIsRefused() {
        #expect(Self.serverToken(prime: []).count == 82)
        let primes: [[UInt8]] = [
            [],
            [0x00, 0x00, 0x00, 0x00],
            [UInt8](repeating: 0xFF, count: 255) + [0xFE],
        ]
        for prime in primes {
            let token = Self.serverToken(prime: prime)
            #expect(throws: TeradataWireError.self) { try Td2Token.parseServerParams(token) }
        }
    }

    @Test("A prime, generator or server key longer than 1,024 bytes is refused")
    func oversizedKeyMaterialIsRefused() {
        let tooLong = [UInt8](repeating: 0xFF, count: Td2Token.maxKeyByteCount + 1)
        let prime = [UInt8](repeating: 0xFF, count: 256)
        let tokens = [
            Self.serverToken(prime: tooLong),
            Self.serverToken(prime: prime, generator: tooLong),
            Self.serverToken(prime: prime, publicKey: tooLong),
        ]
        for token in tokens {
            #expect(throws: TeradataWireError.self) { try Td2Token.parseServerParams(token) }
        }
    }

    @Test("A 2,048-bit odd prime with its generator and key parses as sent")
    func usableParamsParse() throws {
        let prime = [UInt8](repeating: 0xFF, count: 256)
        let params = try Td2Token.parseServerParams(Self.serverToken(prime: prime, generator: [0x02], publicKey: [0x05]))
        #expect(params.prime == prime)
        #expect(params.generator == [0x02])
        #expect(params.serverPublicKey == [0x05])
    }
}
