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

    static func stripQuarantine(at url: URL) {
        let removed = url.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
        guard removed != 0 else { return }
        let code = errno
        guard code != ENOATTR else { return }
        logger.warning("Failed to remove quarantine xattr at \(url.lastPathComponent, privacy: .public): errno=\(code)")
    }
}
