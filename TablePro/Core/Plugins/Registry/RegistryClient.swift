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
    internal let manifestURL: URL

    private var inFlight: InFlightFetch?

    private struct InFlightFetch {
        let policy: RegistryFetchPolicy
        let task: Task<Void, Never>
    }

    internal init(
        manifestURL: URL = RegistryClient.defaultManifestURL,
        session: URLSession = RegistryClient.makeDefaultSession()
    ) {
        self.manifestURL = manifestURL
        self.session = session
        manifest = Self.cachedManifest(for: manifestURL, in: session.configuration.urlCache)
    }

    nonisolated internal static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        // URLCache stores nothing larger than a twentieth of its capacity.
        config.urlCache = URLCache(
            memoryCapacity: 2_000_000,
            diskCapacity: 20_000_000,
            directory: AppStorageEnvironment.shared.applicationSupportRoot
                .appendingPathComponent("TablePro/Registry/URLCache", isDirectory: true)
        )
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

    internal func fetch(policy: RegistryFetchPolicy) async {
        while let current = inFlight {
            await current.task.value
            if policy == .ifStale || current.policy == .mustBeCurrent { return }
        }
        let task = Task { await self.load(policy) }
        inFlight = InFlightFetch(policy: policy, task: task)
        await task.value
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

    private func load(_ policy: RegistryFetchPolicy) async {
        defer { inFlight = nil }
        do {
            let (data, response) = try await session.data(for: makeRequest(policy: policy))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                Self.logger.error("Plugin manifest fetch returned HTTP \(status)")
                isManifestCurrent = false
                return
            }
            let decoded = try JSONDecoder().decode(RegistryManifest.self, from: data)
            manifest = decoded
            isManifestCurrent = true
            Self.logger.info("Fetched the plugin manifest with \(decoded.plugins.count) plugin(s)")
        } catch {
            isManifestCurrent = false
            Self.logger.error("Plugin manifest fetch failed: \(error.publicLogShape, privacy: .public)")
        }
    }
}

internal enum RegistryFetchPolicy: Sendable {
    /// Lets the HTTP cache answer while the response is fresh.
    case ifStale
    case mustBeCurrent
}
