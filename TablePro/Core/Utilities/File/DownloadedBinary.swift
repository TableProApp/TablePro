//
//  DownloadedBinary.swift
//  TablePro
//

import CryptoKit
import Darwin
import Foundation
import os

enum DownloadedBinary {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DownloadedBinary")
    private static let hashChunkSize = 1 << 20

    static func sha256Hex(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: hashChunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            logger.error("Could not read \(path, privacy: .public) to verify its checksum")
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto -xk` writes `com.apple.quarantine` onto every file it extracts, not just the
    /// directory it extracts into, so clearing the bundle root alone leaves the Mach-O inside
    /// `Contents/MacOS` still quarantined. Gatekeeper reads the flag on the file it is about
    /// to map, and refuses a quarantined bundle with "library load disallowed by system
    /// policy" even inside a process that has `com.apple.security.cs.disable-library-validation`.
    static func stripQuarantine(at url: URL) {
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
        logger.warning("Failed to remove quarantine xattr at \(url.lastPathComponent, privacy: .public): errno=\(code)")
    }
}
