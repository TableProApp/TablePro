import Combine
import CryptoKit
import Foundation
import os

@MainActor
internal final class RegistryClient: ObservableObject {
    internal static let shared = RegistryClient()

    nonisolated internal static let defaultManifestURL: URL = {
        guard let url = URL(string: "https://updates.tablepro.app/plugins/v3.json") else {
            preconditionFailure("The plugin manifest URL does not parse")
        }
        return url
    }()

    // Its own key, apart from Sparkle's SUPublicEDKey, which only signs app updates.
    nonisolated internal static let publicKeyInfoKey = "TableProPluginRegistryPublicEDKey"

    nonisolated internal static let bundledPublicKey: Curve25519.Signing.PublicKey = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: publicKeyInfoKey) as? String,
              let raw = Data(base64Encoded: text),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            preconditionFailure("Info.plist has no Ed25519 TableProPluginRegistryPublicEDKey")
        }
        return key
    }()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RegistryClient")

    @Published internal private(set) var manifest: RegistryManifest?
    internal private(set) var isManifestCurrent = false

    internal let session: URLSession
    internal let updatePassSession: URLSession
    internal let manifestURL: URL
    private let verifier: RegistryManifestVerifier

    private var inFlight: InFlightFetch?

    private struct InFlightFetch {
        let policy: RegistryFetchPolicy
        let task: Task<RegistryManifest?, Never>
    }

    private enum LoadOutcome {
        case verified(RegistryManifest)
        case refused
        case failed
    }

    internal init(
        manifestURL: URL = RegistryClient.defaultManifestURL,
        session: URLSession = RegistryClient.makeDefaultSession(),
        publicKey: Curve25519.Signing.PublicKey = RegistryClient.bundledPublicKey,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        let verifier = RegistryManifestVerifier(publicKey: publicKey, defaults: defaults)
        self.manifestURL = manifestURL
        self.session = session
        self.verifier = verifier
        updatePassSession = Self.makeUpdatePassSession(from: session)
        manifest = Self.cachedManifest(at: manifestURL, in: session.configuration.urlCache, verifier: verifier)
    }

    nonisolated internal static func signatureURL(for manifestURL: URL) -> URL {
        manifestURL.appendingPathExtension("sig")
    }

    // The CDN keys its cache on the whole URL, so a query it has never seen goes to the origin.
    nonisolated internal static func bypassingCDNCache(_ url: URL, token: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "refresh", value: token)]
        return components.url ?? url
    }

    nonisolated internal static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.urlCache = makeCache(at: cacheDirectory(in: AppStorageEnvironment.shared.supportDirectory))
        return URLSession(configuration: config)
    }

    nonisolated internal static func cacheDirectory(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Registry/URLCache", isDirectory: true)
    }

    // URLCache stores nothing larger than a twentieth of its capacity. The directory: initializer
    // opens the cache at the percent-encoded path on macOS 15 and earlier (FB9117600).
    nonisolated internal static func makeCache(at directory: URL) -> URLCache {
        URLCache(memoryCapacity: 2_000_000, diskCapacity: 20_000_000, diskPath: directory.path)
    }

    // Shares the interactive session's cache; offline it waits for the network until the resource timeout.
    nonisolated internal static func makeUpdatePassSession(from session: URLSession) -> URLSession {
        let config = session.configuration
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config)
    }

    private static func cachedManifest(
        at url: URL,
        in cache: URLCache?,
        verifier: RegistryManifestVerifier
    ) -> RegistryManifest? {
        guard let cache, let cached = cache.cachedResponse(for: URLRequest(url: url)) else { return nil }
        guard let signature = cache.cachedResponse(for: URLRequest(url: signatureURL(for: url))) else {
            logger.info("Ignoring the cached plugin manifest: its signature is not cached")
            return nil
        }
        do {
            return try verifier.manifest(from: cached.data, signature: signature.data)
        } catch {
            logger.warning("Ignoring the cached plugin manifest: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // The result is this fetch's own; isManifestCurrent also reflects the update pass's fetch.
    @discardableResult
    internal func fetch(policy: RegistryFetchPolicy) async -> RegistryManifest? {
        while let current = inFlight {
            let result = await current.task.value
            if policy == .ifStale || current.policy == .mustBeCurrent { return result }
        }
        let task = Task {
            defer { self.inFlight = nil }
            return await self.load(policy: policy, from: self.session)
        }
        inFlight = InFlightFetch(policy: policy, task: task)
        return await task.value
    }

    // Never coalesced with fetch(policy:), so an interactive caller never waits for the network with the pass.
    internal func fetchWaitingForConnectivity() async -> RegistryManifest? {
        await load(policy: .mustBeCurrent, from: updatePassSession)
    }

    internal func makeRequest(policy: RegistryFetchPolicy) -> URLRequest {
        Self.makeRequest(for: manifestURL, policy: policy)
    }

    nonisolated private static func makeRequest(for url: URL, policy: RegistryFetchPolicy) -> URLRequest {
        var request = URLRequest(url: url)
        switch policy {
        case .ifStale:
            request.cachePolicy = .useProtocolCachePolicy
        case .mustBeCurrent:
            request.cachePolicy = .reloadRevalidatingCacheData
        }
        return request
    }

    private func load(policy: RegistryFetchPolicy, from session: URLSession) async -> RegistryManifest? {
        var outcome = await loadVerified(policy: policy, from: session, bypassingCDNCache: nil)
        if case .refused = outcome {
            // The manifest and its signature are cached apart, so a deploy between them leaves a pair that disagrees.
            Self.logger.info("Fetching the plugin manifest and its signature again from the server")
            outcome = await loadVerified(policy: .mustBeCurrent, from: session, bypassingCDNCache: UUID().uuidString)
        }
        switch outcome {
        case .verified(let decoded):
            manifest = decoded
            isManifestCurrent = true
            Self.logger.info("Fetched the plugin manifest with \(decoded.plugins.count) plugin(s)")
            return decoded
        case .refused, .failed:
            isManifestCurrent = false
            return nil
        }
    }

    private func loadVerified(
        policy: RegistryFetchPolicy,
        from session: URLSession,
        bypassingCDNCache token: String?
    ) async -> LoadOutcome {
        let signatureURL = Self.signatureURL(for: manifestURL)
        let urls = token.map {
            (Self.bypassingCDNCache(manifestURL, token: $0), Self.bypassingCDNCache(signatureURL, token: $0))
        } ?? (manifestURL, signatureURL)
        let manifestRequest = Self.makeRequest(for: urls.0, policy: policy)
        let signatureRequest = Self.makeRequest(for: urls.1, policy: policy)
        let data: Data
        let signature: Data
        let manifestHTTPResponse: URLResponse
        let signatureHTTPResponse: URLResponse
        do {
            async let manifestResponse = session.data(for: manifestRequest)
            async let signatureResponse = session.data(for: signatureRequest)
            let (manifestData, response) = try await manifestResponse
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                Self.logger.error("Plugin manifest fetch returned HTTP \(status)")
                return .failed
            }
            let (signatureData, signatureFetchResponse) = try await signatureResponse
            let signatureStatus = (signatureFetchResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(signatureStatus) else {
                Self.logger.error("Plugin manifest signature fetch returned HTTP \(signatureStatus)")
                return .refused
            }
            data = manifestData
            signature = signatureData
            manifestHTTPResponse = response
            signatureHTTPResponse = signatureFetchResponse
        } catch {
            Self.logger.error("Plugin manifest fetch failed: \(error.publicLogShape, privacy: .public)")
            return .failed
        }
        let decoded: RegistryManifest
        do {
            decoded = try verifier.manifest(from: data, signature: signature)
        } catch {
            Self.logger.error("Refused the plugin manifest: \(error.publicLogShape, privacy: .public)")
            return .refused
        }
        // The next launch reads the cached pair at the plain URLs, which still hold the pair that disagreed.
        if token != nil, let cache = session.configuration.urlCache {
            Self.recache(data, from: manifestHTTPResponse, fetchedAt: urls.0, as: manifestURL, in: cache)
            Self.recache(signature, from: signatureHTTPResponse, fetchedAt: urls.1, as: signatureURL, in: cache)
        }
        return .verified(decoded)
    }

    nonisolated private static func recache(
        _ data: Data,
        from response: URLResponse,
        fetchedAt fetchedURL: URL,
        as url: URL,
        in cache: URLCache
    ) {
        cache.removeCachedResponse(for: URLRequest(url: fetchedURL))
        let headers = (response as? HTTPURLResponse)?.allHeaderFields as? [String: String]
        guard let plain = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return
        }
        cache.storeCachedResponse(CachedURLResponse(response: plain, data: data), for: URLRequest(url: url))
    }
}

internal enum RegistryFetchPolicy: Sendable {
    // Lets the HTTP cache answer while the response is fresh.
    case ifStale
    case mustBeCurrent
}
