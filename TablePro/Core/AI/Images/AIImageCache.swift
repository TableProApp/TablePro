//
//  AIImageCache.swift
//  TablePro
//

import AppKit
import Foundation
import os

final class AIImageCache: @unchecked Sendable {
    static let shared = AIImageCache()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AIImageCache")

    private let cacheDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base
            .appendingPathComponent("com.TablePro", isDirectory: true)
            .appendingPathComponent("AIChatImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func store(data: Data, mediaType: String) -> String {
        let ext = fileExtension(for: mediaType)
        let filename = "\(UUID().uuidString).\(ext)"
        let url = cacheDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to write image: \(error.localizedDescription, privacy: .public)")
        }
        return filename
    }

    func read(filename: String) -> Data? {
        try? Data(contentsOf: cacheDirectory.appendingPathComponent(filename))
    }

    func loadImage(filename: String) -> NSImage? {
        guard let data = read(filename: filename) else { return nil }
        return NSImage(data: data)
    }

    func delete(filename: String) {
        let url = cacheDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    func purgeOlderThan(seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls {
            let resources = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = resources?.contentModificationDate, date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/png":  return "png"
        case "image/jpeg": return "jpg"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        default:           return "img"
        }
    }
}
