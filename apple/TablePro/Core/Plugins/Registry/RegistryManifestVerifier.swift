import CryptoKit
import Foundation

internal enum RegistryManifestRefusal: Error, Equatable {
    case malformedSignature
    case signatureMismatch
    case missingSerial
    case replayed(serial: Int, highestSeen: Int)
}

internal struct RegistryManifestVerifier {
    internal let publicKey: Curve25519.Signing.PublicKey
    internal let defaults: UserDefaults

    private struct Serial: Decodable {
        let serial: Int?
    }

    // The signature covers the bytes as served, so nothing is decoded before it is checked.
    internal func manifest(from data: Data, signature: Data) throws -> RegistryManifest {
        guard let signatureBytes = Data(base64Encoded: signature, options: .ignoreUnknownCharacters),
              signatureBytes.count == 64 else {
            throw RegistryManifestRefusal.malformedSignature
        }
        guard publicKey.isValidSignature(signatureBytes, for: data) else {
            throw RegistryManifestRefusal.signatureMismatch
        }
        guard let serial = try JSONDecoder().decode(Serial.self, from: data).serial else {
            throw RegistryManifestRefusal.missingSerial
        }
        let key = PreferenceKeys.pluginRegistrySerial.name
        let highestSeen = defaults.object(forKey: key) as? Int
        if let highestSeen, serial < highestSeen {
            throw RegistryManifestRefusal.replayed(serial: serial, highestSeen: highestSeen)
        }
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: data)
        if serial > highestSeen ?? .min {
            defaults.set(serial, forKey: key)
        }
        return manifest
    }
}
