//
//  DownloadCountService.swift
//  TablePro
//

import Foundation
import os

@MainActor @Observable
final class DownloadCountService {
    static let shared = DownloadCountService()

    private var counts: [String: Int] = [:]
    private var lastFetchDate: Date?
    private static let cooldown: TimeInterval = 300 // 5 minutes
    private static let logger = Logger(subsystem: "com.TablePro", category: "DownloadCountService")

    // swiftlint:disable:next force_unwrapping
    private static let releasesURL = URL(string: "https://api.github.com/repos/datlechin/TablePro/releases?per_page=100")!

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public

    func downloadCount(for pluginId: String) -> Int? {
        counts[pluginId]
    }

    func fetchCounts(for manifest: RegistryManifest?) async {
        guard let manifest else { return }

        if let lastFetchDate, Date().timeIntervalSince(lastFetchDate) < Self.cooldown {
            return
        }

        do {
            let releases = try await fetchReleases()
            let pluginReleases = releases.filter { $0.tagName.hasPrefix("plugin-") }
            let tagPrefixToPluginId = buildTagPrefixMap(from: manifest)

            var totals: [String: Int] = [:]
            for release in pluginReleases {
                let tagPrefix = extractTagPrefix(from: release.tagName)
                guard let pluginId = tagPrefixToPluginId[tagPrefix] else { continue }
                let releaseTotal = release.assets.reduce(0) { $0 + $1.downloadCount }
                totals[pluginId, default: 0] += releaseTotal
            }

            counts = totals
            lastFetchDate = Date()
            Self.logger.info("Fetched download counts for \(totals.count) plugin(s)")
        } catch {
            Self.logger.error("Failed to fetch download counts: \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub API

    private func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    // MARK: - Tag Prefix Mapping

    private func buildTagPrefixMap(from manifest: RegistryManifest) -> [String: String] {
        var map: [String: String] = [:]
        for plugin in manifest.plugins {
            let url = plugin.binaries?.first?.downloadURL ?? plugin.downloadURL
            guard let url else { continue }
            guard let tagComponent = extractTagComponent(from: url) else { continue }
            let prefix = extractTagPrefix(from: tagComponent)
            map[prefix] = plugin.id
        }
        return map
    }

    private func extractTagComponent(from downloadURL: String) -> String? {
        guard let url = URL(string: downloadURL) else { return nil }
        let components = url.pathComponents
        guard let downloadIndex = components.firstIndex(of: "download"),
              downloadIndex + 1 < components.count else { return nil }
        return components[downloadIndex + 1]
    }

    private func extractTagPrefix(from tag: String) -> String {
        guard let range = tag.range(of: #"-v\d"#, options: .regularExpression) else { return tag }
        return String(tag[tag.startIndex..<range.lowerBound])
    }
}

// MARK: - GitHub API Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let downloadCount: Int
    let browserDownloadUrl: String
}
