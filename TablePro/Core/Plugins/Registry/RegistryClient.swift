//
//  RegistryClient.swift
//  TablePro
//

import Foundation
import os

@MainActor @Observable
final class RegistryClient {
    static let shared = RegistryClient()

    private(set) var manifest: RegistryManifest?
    private(set) var fetchState: RegistryFetchState = .idle
    private(set) var lastFetchDate: Date?

    let session: URLSession
    static let supportedSchemaVersion = 2
    private static let logger = Logger(subsystem: "com.TablePro", category: "RegistryClient")
    private static let manifestFreshnessWindow: TimeInterval = 300

    private static let defaultRegistryURL = URL(string:
        "https://raw.githubusercontent.com/TableProApp/plugins/main/plugins.json")!

    static let customRegistryURLKey = "com.TablePro.customRegistryURL"
    private static let lastFetchKey = "com.TablePro.registryLastFetch"
    private static let legacyManifestCacheKey = "registryManifestCache"
    private static let legacyETagKeys = ["registryETag", "com.TablePro.registryETag"]
    private static let legacyLastFetchKey = "registryLastFetch"
    private static let legacyLastRegistryURLKey = "com.TablePro.lastRegistryURL"

    private let defaults: UserDefaults
    private let manifestCacheURL: URL

    @ObservationIgnored private var inFlightFetch: Task<Void, Never>?
    @ObservationIgnored private var lastFetchedURL: URL?

    var isUsingCustomRegistry: Bool {
        registryURL != Self.defaultRegistryURL
    }

    private var registryURL: URL {
        if let raw = defaults.string(forKey: Self.customRegistryURLKey),
           let custom = URL(string: raw) {
            return custom
        }
        return Self.defaultRegistryURL
    }

    private static let manifestCacheFileName = "registry-manifest.json"

    init(
        userDefaults: UserDefaults = .standard,
        session: URLSession = RegistryClient.makeDefaultSession(),
        manifestCacheURL: URL = RegistryClient.defaultManifestCacheURL()
    ) {
        self.defaults = userDefaults
        self.session = session
        self.manifestCacheURL = manifestCacheURL
        Self.migrateLegacyKeys(in: userDefaults)
        migrateManifestCacheLocationIfNeeded()
        loadCachedManifest()
    }

    nonisolated static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.urlCache = URLCache(
            memoryCapacity: 1_000_000,
            diskCapacity: 5_000_000,
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TablePro/Registry/URLCache", isDirectory: true)
        )
        return URLSession(configuration: config)
    }

    nonisolated static func defaultManifestCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Registry", isDirectory: true)
            .appendingPathComponent(manifestCacheFileName)
    }

    private static func migrateLegacyKeys(in defaults: UserDefaults) {
        let obsoleteKeys = legacyETagKeys + [legacyLastFetchKey, legacyManifestCacheKey, legacyLastRegistryURLKey]
        for key in obsoleteKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateManifestCacheLocationIfNeeded() {
        guard manifestCacheURL == Self.defaultManifestCacheURL() else { return }
        let fm = FileManager.default
        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.TablePro"
        let legacyURL = cachesDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent(Self.manifestCacheFileName)
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        if !fm.fileExists(atPath: manifestCacheURL.path) {
            do {
                try fm.createDirectory(
                    at: manifestCacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: legacyURL, to: manifestCacheURL)
            } catch {
                Self.logger.warning("Failed to migrate registry manifest cache: \(error.localizedDescription)")
                return
            }
        }
        try? fm.removeItem(at: legacyURL)
    }

    private func loadCachedManifest() {
        guard let data = try? Data(contentsOf: manifestCacheURL),
              let cached = try? JSONDecoder().decode(RegistryManifest.self, from: data)
        else { return }
        manifest = cached
        lastFetchDate = defaults.object(forKey: Self.lastFetchKey) as? Date
    }

    private func writeCachedManifest(_ data: Data) {
        let dir = manifestCacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: manifestCacheURL, options: .atomic)
        } catch {
            Self.logger.warning("Failed to write registry cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetching

    func ensureManifest(_ intent: RegistryFetchIntent) async {
        if let inFlightFetch {
            await inFlightFetch.value
            return
        }
        if intent == .ifStale, !needsRefresh { return }
        let task = Task { await fetchManifest() }
        inFlightFetch = task
        await task.value
        inFlightFetch = nil
    }

    private var needsRefresh: Bool {
        guard lastFetchedURL == registryURL, let lastFetchDate else { return true }
        return Date().timeIntervalSince(lastFetchDate) > Self.manifestFreshnessWindow
    }

    func fetchManifest(forceRefresh: Bool = false) async {
        fetchState = .loading

        let request = makeManifestRequest(forceRefresh: forceRefresh)
        if isUsingCustomRegistry {
            Self.logger.warning("Using custom plugin registry URL: \(self.registryURL.absoluteString)")
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            switch httpResponse.statusCode {
            case 200...299:
                let decoded = try JSONDecoder().decode(RegistryManifest.self, from: data)

                if decoded.schemaVersion > Self.supportedSchemaVersion {
                    Self.logger.error(
                        "Registry schemaVersion \(decoded.schemaVersion) is newer than supported \(Self.supportedSchemaVersion); falling back to cached manifest"
                    )
                    fallbackToCacheOrFail(
                        message: String(localized: "Plugin registry requires a newer app version")
                    )
                    return
                }

                manifest = decoded

                writeCachedManifest(data)
                lastFetchDate = Date()
                lastFetchedURL = request.url
                defaults.set(lastFetchDate, forKey: Self.lastFetchKey)

                fetchState = .loaded
                Self.logger.info("Fetched registry manifest with \(decoded.plugins.count) plugin(s)")

            default:
                let message = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                Self.logger.error("Registry fetch failed: HTTP \(httpResponse.statusCode) \(message)")
                fallbackToCacheOrFail(message: "Server returned HTTP \(httpResponse.statusCode)")
            }
        } catch is DecodingError {
            Self.logger.error("Failed to decode registry manifest")
            fallbackToCacheOrFail(message: String(localized: "Failed to parse plugin registry"))
        } catch {
            Self.logger.error("Registry fetch failed: \(error.localizedDescription)")
            fallbackToCacheOrFail(message: error.localizedDescription)
        }
    }

    func makeManifestRequest(forceRefresh: Bool) -> URLRequest {
        var request = URLRequest(url: registryURL)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalCacheData : .reloadRevalidatingCacheData
        return request
    }

    func refreshedPlugin(matching plugin: RegistryPlugin) async -> RegistryPlugin {
        await fetchManifest(forceRefresh: true)
        return manifest?.plugins.first { $0.id == plugin.id } ?? plugin
    }

    private func fallbackToCacheOrFail(message: String) {
        if manifest != nil {
            fetchState = .loadedFromCache(message)
            Self.logger.warning("Using cached registry manifest after fetch failure")
        } else {
            fetchState = .failed(message)
        }
    }

    // MARK: - Search

    func search(query: String, category: RegistryCategory?) -> [RegistryPlugin] {
        guard let plugins = manifest?.plugins else { return [] }

        var filtered = plugins

        if let category {
            filtered = filtered.filter { $0.category == category }
        }

        if !query.isEmpty {
            let lowercased = query.lowercased()
            filtered = filtered.filter { plugin in
                plugin.name.lowercased().contains(lowercased)
                    || plugin.summary.lowercased().contains(lowercased)
                    || plugin.author.name.lowercased().contains(lowercased)
            }
        }

        return filtered
    }
}

enum RegistryFetchIntent: Equatable, Sendable {
    case ifStale
    case mustBeCurrent
}

enum RegistryFetchState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case loadedFromCache(String)
    case failed(String)
}
