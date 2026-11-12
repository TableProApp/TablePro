import CryptoKit
import Darwin
import Foundation
import os

public enum DownloadedBinary {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DownloadedBinary")
    private static let hashChunkSize = 1 << 20

    public static func sha256Hex(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            // Each read returns an autoreleased buffer, and the caller's job may not drain its pool until the whole file is read.
            while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: hashChunkSize) }), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            logger.error("Could not read \(path, privacy: .private(mask: .hash)) to verify its checksum")
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // `ditto -xk` quarantines every extracted file, and Gatekeeper refuses to map a quarantined Mach-O even with library validation off.
    public static func stripQuarantine(at url: URL) {
        stripQuarantineFromSingleItem(at: url)

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for case let child as URL in enumerator {
            stripQuarantineFromSingleItem(at: child)
        }
    }

    private static func stripQuarantineFromSingleItem(at url: URL) {
        let removed = url.path.withCString { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
        guard removed != 0 else { return }
        let code = errno
        guard code != ENOATTR else { return }
        logger.warning("Failed to remove quarantine xattr at \(url.lastPathComponent, privacy: .private(mask: .hash)): errno=\(code)")
    }
}
