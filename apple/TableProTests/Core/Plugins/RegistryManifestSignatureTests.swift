import CryptoKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct RegistryManifestSignatureTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private var verifier: RegistryManifestVerifier {
        RegistryManifestVerifier(publicKey: SignedRegistryManifest.key.publicKey, defaults: suite.defaults)
    }

    private var storedSerial: Int? {
        suite.defaults.object(forKey: PreferenceKeys.pluginRegistrySerial.name) as? Int
    }

    private let oraclePlugin = """
    {"id": "com.TablePro.OracleDriver", "name": "Oracle Driver", "databaseTypeIds": ["Oracle"], "exportFormatIds": [],
     "releases": [{"version": "9.9.9", "build": 99999999, "channel": "stable", "pluginKit": 40,
                   "minimumSystemVersion": "1.0", "url": "https://mirror.attacker.example/OracleDriver-0.82.0.zip",
                   "sha256": "deadbeef"}]}
    """

    private func refusal(_ body: Data, signature: Data) -> RegistryManifestRefusal? {
        do {
            _ = try verifier.manifest(from: body, signature: signature)
            return nil
        } catch {
            return error as? RegistryManifestRefusal
        }
    }

    private func store(_ data: Data, at url: URL, in cache: URLCache) throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))
    }

    private func makeClient(
        cached: (manifest: Data, signature: Data?)? = nil,
        at manifestURL: URL? = nil,
        cache: URLCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0, directory: nil)
    ) throws -> RegistryClient {
        let url = try manifestURL ?? #require(URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json"))
        if let cached {
            try store(cached.manifest, at: url, in: cache)
            if let signature = cached.signature {
                try store(signature, at: SignedRegistryManifest.signatureURL(for: url), in: cache)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryStubProtocol.self]
        configuration.urlCache = cache
        return SignedRegistryManifest.client(
            manifestURL: url,
            session: URLSession(configuration: configuration),
            defaults: suite.defaults
        )
    }

    private func serve(_ manifest: Data, signature: Data, to client: RegistryClient) {
        RegistryStubProtocol.enqueue([(200, manifest)], at: client.manifestURL)
        RegistryStubProtocol.enqueue([(200, signature)], at: SignedRegistryManifest.signatureURL(for: client.manifestURL))
    }

    @Test("The report's manifest with no signature is refused")
    func unsignedManifestIsRefused() async throws {
        let hostile = SignedRegistryManifest.manifest(plugins: [oraclePlugin])
        #expect(refusal(hostile, signature: Data()) == .malformedSignature)

        let client = try makeClient()
        RegistryStubProtocol.enqueue([(200, hostile)], at: client.manifestURL)

        #expect(await client.fetchWaitingForConnectivity() == nil)
        #expect(client.manifest == nil)
        #expect(!client.isManifestCurrent)
    }

    @Test("A manifest signed by another key is refused")
    func otherKeyIsRefused() throws {
        let hostile = SignedRegistryManifest.manifest(plugins: [oraclePlugin])
        let signature = try SignedRegistryManifest.signature(of: hostile, by: Curve25519.Signing.PrivateKey())

        #expect(refusal(hostile, signature: signature) == .signatureMismatch)
    }

    @Test("Bytes that differ from the signed ones are refused, and the last verified manifest stays")
    func tamperedBytesAreRefused() async throws {
        let signed = SignedRegistryManifest.manifest(plugins: [oraclePlugin])
        let signature = try SignedRegistryManifest.signature(of: signed)
        let tampered = Data(String(decoding: signed, as: UTF8.self).replacingOccurrences(of: "40", with: "39").utf8)
        #expect(refusal(tampered, signature: signature) == .signatureMismatch)

        let client = try makeClient(cached: (signed, signature))
        serve(tampered, signature: signature, to: client)

        #expect(await client.fetch(policy: .mustBeCurrent) == nil)
        #expect(client.manifest?.plugins.first?.releases.first?.pluginKit == 40)
        #expect(!client.isManifestCurrent)
    }

    @Test("A signed manifest older than one already accepted is refused; the same one or a newer one is not")
    func olderSerialIsRefused() throws {
        suite.defaults.set(7, forKey: PreferenceKeys.pluginRegistrySerial.name)
        let older = SignedRegistryManifest.manifest(serial: 6)
        let same = SignedRegistryManifest.manifest(serial: 7)
        let newer = SignedRegistryManifest.manifest(serial: 8)

        let olderSignature = try SignedRegistryManifest.signature(of: older)

        #expect(refusal(older, signature: olderSignature) == .replayed(serial: 6, highestSeen: 7))
        #expect(storedSerial == 7)
        _ = try verifier.manifest(from: same, signature: SignedRegistryManifest.signature(of: same))
        #expect(storedSerial == 7)
        _ = try verifier.manifest(from: newer, signature: SignedRegistryManifest.signature(of: newer))
        #expect(storedSerial == 8)
    }

    @Test("A signed manifest with no serial is refused")
    func missingSerialIsRefused() throws {
        let body = SignedRegistryManifest.manifest(serial: nil)
        let signature = try SignedRegistryManifest.signature(of: body)

        #expect(refusal(body, signature: signature) == .missingSerial)
        #expect(storedSerial == nil)
    }

    @Test("The cached manifest is read at launch only with its cached signature")
    func cachedManifestNeedsCachedSignature() throws {
        let body = SignedRegistryManifest.manifest(plugins: [oraclePlugin])
        let signature = try SignedRegistryManifest.signature(of: body)
        let otherSignature = try SignedRegistryManifest.signature(of: SignedRegistryManifest.manifest(serial: 2))

        let unsigned = try makeClient(cached: (body, nil))
        let misSigned = try makeClient(cached: (body, otherSignature))
        let signed = try makeClient(cached: (body, signature))

        #expect(unsigned.manifest == nil)
        #expect(misSigned.manifest == nil)
        #expect(signed.manifest?.plugins.map { $0.id } == ["com.TablePro.OracleDriver"])
    }

    @Test("A fetch whose pair disagrees fetches both files once more, past the CDN's cache", arguments: [
        RegistryFetchPolicy.ifStale, .mustBeCurrent
    ])
    func retriesOnceWhenThePairDisagrees(policy: RegistryFetchPolicy) async throws {
        let older = SignedRegistryManifest.manifest(serial: 1)
        let newer = SignedRegistryManifest.manifest(serial: 2, plugins: [oraclePlugin])
        let cache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0, directory: nil)
        let client = try makeClient(cache: cache)
        let olderSignature = try SignedRegistryManifest.signature(of: older)
        let newerSignature = try SignedRegistryManifest.signature(of: newer)
        serve(newer, signature: olderSignature, to: client)
        serve(newer, signature: newerSignature, to: client)
        let signatureURL = SignedRegistryManifest.signatureURL(for: client.manifestURL)

        let fetched = await client.fetch(policy: policy)

        #expect(fetched?.plugins.count == 1)
        #expect(client.isManifestCurrent)
        #expect(storedSerial == 2)
        let manifestQueries = RegistryStubProtocol.requestedURLs(for: client.manifestURL).map { $0.query }
        let signatureQueries = RegistryStubProtocol.requestedURLs(for: signatureURL).map { $0.query }
        #expect(manifestQueries.count == 2)
        #expect(manifestQueries.first == .some(nil))
        #expect(manifestQueries.last??.hasPrefix("refresh=") == true)
        #expect(signatureQueries == manifestQueries)

        let relaunched = try makeClient(at: client.manifestURL, cache: cache)
        #expect(relaunched.manifest?.plugins.map { $0.id } == ["com.TablePro.OracleDriver"])
    }

    @Test("A pair that still disagrees after the one retry is refused")
    func retriesOnlyOnce() async throws {
        let body = SignedRegistryManifest.manifest()
        let client = try makeClient()
        let otherKeySignature = try SignedRegistryManifest.signature(of: body, by: Curve25519.Signing.PrivateKey())
        serve(body, signature: otherKeySignature, to: client)
        serve(body, signature: otherKeySignature, to: client)
        serve(body, signature: otherKeySignature, to: client)

        #expect(await client.fetch(policy: .mustBeCurrent) == nil)
        #expect(!client.isManifestCurrent)
        #expect(RegistryStubProtocol.requestCount(for: client.manifestURL) == 2)
    }

    @Test("The shipped client verifies with the registry's own key, never Sparkle's")
    func defaultKeyIsTheRegistryKey() throws {
        let registryKey = try #require(Bundle.main.object(forInfoDictionaryKey: "TableProPluginRegistryPublicEDKey") as? String)
        let sparkleKey = try #require(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)

        #expect(registryKey == "IsE0vGXqPdxMY8cRrdi1B61ju4heTs+/cOXISYjs2tE=")
        #expect(RegistryClient.bundledPublicKey.rawRepresentation == Data(base64Encoded: registryKey))
        #expect(registryKey != sparkleKey)
    }
}
