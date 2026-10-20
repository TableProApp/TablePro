import Combine
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

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RegistryClient")

    @Published internal private(set) var manifest: RegistryManifest?
    internal private(set) var isManifestCurrent = false

    internal let session: URLSession
    internal let updatePassSession: URLSession
    internal let manifestURL: URL

    private var inFlight: InFlightFetch?

    private struct InFlightFetch {
        let policy: RegistryFetchPolicy
        let task: Task<RegistryManifest?, Never>
    }

    internal init(
        manifestURL: URL = RegistryClient.defaultManifestURL,
        session: URLSession = RegistryClient.makeDefaultSession()
    ) {
        self.manifestURL = manifestURL
        self.session = session
        updatePassSession = Self.makeUpdatePassSession(from: session)
        manifest = Self.cachedManifest(for: manifestURL, in: session.configuration.urlCache)
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

    nonisolated private static func cachedManifest(for url: URL, in cache: URLCache?) -> RegistryManifest? {
        guard let cached = cache?.cachedResponse(for: URLRequest(url: url)) else { return nil }
        do {
            return try JSONDecoder().decode(RegistryManifest.self, from: cached.data)
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
            return await self.load(self.makeRequest(policy: policy), from: self.session)
        }
        inFlight = InFlightFetch(policy: policy, task: task)
        return await task.value
    }

    // Never coalesced with fetch(policy:), so an interactive caller never waits for the network with the pass.
    internal func fetchWaitingForConnectivity() async -> RegistryManifest? {
        await load(makeRequest(policy: .mustBeCurrent), from: updatePassSession)
    }

    internal func makeRequest(policy: RegistryFetchPolicy) -> URLRequest {
        var request = URLRequest(url: manifestURL)
        switch policy {
        case .ifStale:
            request.cachePolicy = .useProtocolCachePolicy
        case .mustBeCurrent:
            request.cachePolicy = .reloadRevalidatingCacheData
        }
        return request
    }

    private func load(_ request: URLRequest, from session: URLSession) async -> RegistryManifest? {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                Self.logger.error("Plugin manifest fetch returned HTTP \(status)")
                isManifestCurrent = false
                return nil
            }
            let decoded = try JSONDecoder().decode(RegistryManifest.self, from: data)
            manifest = decoded
            isManifestCurrent = true
            Self.logger.info("Fetched the plugin manifest with \(decoded.plugins.count) plugin(s)")
            return decoded
        } catch {
            isManifestCurrent = false
            Self.logger.error("Plugin manifest fetch failed: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }
}

internal enum RegistryFetchPolicy: Sendable {
    /// Lets the HTTP cache answer while the response is fresh.
    case ifStale
    case mustBeCurrent
}
