import Foundation

/// Credentials survive only inside an encrypted file: plain decode drops them and plain encode refuses them.
public enum ConnectionBundleCodec {
    public static func isEncrypted(_ data: Data) -> Bool {
        ConnectionExportCrypto.isEncrypted(data)
    }

    public static func decode(_ data: Data) throws -> ConnectionBundle {
        guard !isEncrypted(data) else { throw ConnectionBundleError.requiresPassphrase }
        return try decodeJSON(data).withoutCredentials()
    }

    @concurrent
    public static func decode(_ data: Data, passphrase: String) async throws -> ConnectionBundle {
        let json: Data
        do {
            json = try await ConnectionExportCrypto.decrypt(data: data, passphrase: passphrase)
        } catch {
            throw ConnectionBundleError.decryptionFailed(error.localizedDescription)
        }
        return try decodeJSON(json)
    }

    public static func encode(_ bundle: ConnectionBundle) throws -> Data {
        guard bundle.credentials.isEmpty else { throw ConnectionBundleError.credentialsRequireEncryption }
        return try encodeJSON(bundle)
    }

    /// An empty passphrase encrypts nothing, so the bundle is written as plain JSON and must carry no credentials.
    @concurrent
    public static func encode(_ bundle: ConnectionBundle, passphrase: String) async throws -> Data {
        guard !passphrase.isEmpty else { return try encode(bundle) }
        let json = try encodeJSON(bundle)
        do {
            return try await ConnectionExportCrypto.encrypt(data: json, passphrase: passphrase)
        } catch {
            throw ConnectionBundleError.encodingFailed
        }
    }

    private struct VersionProbe: Decodable {
        let formatVersion: Int
    }

    private static func decodeJSON(_ data: Data) throws -> ConnectionBundle {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.formatVersion >= 1 else {
            throw ConnectionBundleError.invalidFormat
        }
        guard probe.formatVersion <= ConnectionBundle.formatVersion else {
            throw ConnectionBundleError.unsupportedVersion(probe.formatVersion)
        }
        if probe.formatVersion == 1 {
            let envelope = try decodeBody(ConnectionBundleV1.Envelope.self, from: data)
            return try envelope.upgraded().mappingSettings { $0.sanitizedForImport() }
        }
        let payload = try decodeBody(ConnectionBundlePayload.self, from: data)
        return try payload.bundle(sanitizing: { $0.sanitizedForImport() })
    }

    private static func decodeBody<Body: Decodable>(_ type: Body.Type, from data: Data) throws -> Body {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ConnectionBundleError.decodingFailed(error.localizedDescription)
        }
    }

    private static func encodeJSON(_ bundle: ConnectionBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(bundle)
        } catch {
            throw ConnectionBundleError.encodingFailed
        }
    }
}
