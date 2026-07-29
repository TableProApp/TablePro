import Foundation
import Security

struct DiffieHellman {
    let prime: BigUInt
    let generator: BigUInt
    let modulusByteCount: Int
    let privateExponent: BigUInt
    let publicKey: BigUInt

    init(primeBytes: [UInt8], generatorBytes: [UInt8], privateExponentBytes: [UInt8]? = nil) {
        prime = BigUInt(bytesBE: primeBytes)
        generator = BigUInt(bytesBE: generatorBytes)
        modulusByteCount = prime.byteCount
        let exponentBytes = privateExponentBytes ?? DiffieHellman.randomBytes(64)
        privateExponent = BigUInt(bytesBE: exponentBytes)
        publicKey = generator.modPow(privateExponent, modulus: prime)
    }

    func publicKeyBytes() -> [UInt8] {
        publicKey.bytesBE(minCount: modulusByteCount)
    }

    func sharedSecret(peerPublicKeyBytes: [UInt8]) -> [UInt8] {
        let peer = BigUInt(bytesBE: peerPublicKeyBytes)
        return peer.modPow(privateExponent, modulus: prime).bytesBE(minCount: modulusByteCount)
    }

    func masterKeyNormalizeTemp(peerPublicKeyBytes: [UInt8]) -> [UInt8] {
        let peer = BigUInt(bytesBE: peerPublicKeyBytes)
        var magnitude = peer.modPow(privateExponent, modulus: prime).bytesBE()
        if magnitude.count < modulusByteCount {
            magnitude += [UInt8](repeating: 0, count: modulusByteCount - magnitude.count)
        } else if magnitude.count > modulusByteCount {
            magnitude = Array(magnitude.suffix(modulusByteCount))
        }
        return magnitude
    }

    static func deriveKey(fromSharedSecret secret: [UInt8], offset: Int, length: Int) -> [UInt8] {
        guard offset + length <= secret.count else { return [] }
        return Array(secret[offset..<offset + length])
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}
