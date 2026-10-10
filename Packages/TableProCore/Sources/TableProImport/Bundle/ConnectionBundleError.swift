import Foundation

public enum ConnectionBundleError: LocalizedError, Equatable {
    case invalidFormat
    case unsupportedVersion(Int)
    case decodingFailed(String)
    case invalidBundle(String)
    case requiresPassphrase
    case decryptionFailed(String)
    case encodingFailed
    case credentialsRequireEncryption

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            String(localized: "This file is not a valid TablePro export")
        case .unsupportedVersion(let version):
            String(format: String(localized: "This file requires a newer version of TablePro (format version %d)"), version)
        case .decodingFailed(let detail):
            String(format: String(localized: "Failed to parse connection file: %@"), detail)
        case .invalidBundle(let detail):
            String(format: String(localized: "This file is not a valid TablePro export: %@"), detail)
        case .requiresPassphrase:
            String(localized: "This file is encrypted and requires a passphrase")
        case .decryptionFailed(let detail):
            String(format: String(localized: "Decryption failed: %@"), detail)
        case .encodingFailed:
            String(localized: "Failed to encode connection data")
        case .credentialsRequireEncryption:
            String(localized: "Saved passwords can only be exported to an encrypted file.")
        }
    }
}
