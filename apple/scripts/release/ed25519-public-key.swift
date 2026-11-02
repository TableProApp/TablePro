// Prints the base64 Ed25519 public key of the base64 seed on stdin, the format `generate_keys -x` exports.
import CryptoKit
import Foundation

guard let input = String(bytes: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let seed = Data(base64Encoded: input), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("stdin is not a base64 32-byte Ed25519 seed\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
