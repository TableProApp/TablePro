import AppKit
import Foundation
import ImageIO
import os

/// Disk-backed cache for chat-attached images. File operations are serialised
/// on `queue`; `cacheDirectory` is immutable after init so reads can also run
/// concurrently from any thread. Filenames decoded from history are checked
/// to belong to the cache directory, defending against `../` traversal.
final class AIImageCache: @unchecked Sendable {
    static let shared = AIImageCache()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AIImageCache")

    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "com.TablePro.AIImageCache", qos: .utility)
    /// `NSCache` is safe to use from any thread.
    private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

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
        queue.sync {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Self.logger.error("Failed to write image: \(error.publicLogShape, privacy: .public)")
            }
        }
        return filename
    }

    func read(filename: String) -> Data? {
        guard let url = safeURL(for: filename) else { return nil }
        return queue.sync { try? Data(contentsOf: url) }
    }

    func loadImage(filename: String) -> NSImage? {
        guard let data = read(filename: filename) else { return nil }
        return NSImage(data: data)
    }

    /// The image scaled down to `maxPixelSize` on its longer side by ImageIO, which never keeps the full-size bitmap.
    /// A pasted screenshot is up to 2000 px, and drawing it into a 96 pt thumbnail decoded all of it each time its
    /// transcript row came back into view.
    func thumbnail(filename: String, maxPixelSize: Int) -> NSImage? {
        if let cached = cachedThumbnail(filename: filename, maxPixelSize: maxPixelSize) {
            return cached
        }
        guard let url = safeURL(for: filename),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        thumbnails.setObject(thumbnail, forKey: thumbnailKey(filename: filename, maxPixelSize: maxPixelSize))
        return thumbnail
    }

    /// A thumbnail already made, without touching the disk, so a row that scrolls back in draws it on its first frame.
    func cachedThumbnail(filename: String, maxPixelSize: Int) -> NSImage? {
        thumbnails.object(forKey: thumbnailKey(filename: filename, maxPixelSize: maxPixelSize))
    }

    private func thumbnailKey(filename: String, maxPixelSize: Int) -> NSString {
        "\(maxPixelSize)/\(filename)" as NSString
    }

    func delete(filename: String) {
        guard let url = safeURL(for: filename) else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func purgeOlderThan(seconds: TimeInterval) {
        queue.sync {
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
    }

    /// Resolves a filename to a URL only when it stays inside `cacheDirectory`.
    /// Rejects empty input, path separators, parent-directory components, and
    /// any symlink-resolved path that escapes the cache root.
    private func safeURL(for filename: String) -> URL? {
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              filename != ".",
              filename != ".."
        else { return nil }
        let candidate = cacheDirectory.appendingPathComponent(filename).standardizedFileURL
        let root = cacheDirectory.standardizedFileURL.path
        guard candidate.path.hasPrefix(root + "/") || candidate.path == root else { return nil }
        return candidate
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
