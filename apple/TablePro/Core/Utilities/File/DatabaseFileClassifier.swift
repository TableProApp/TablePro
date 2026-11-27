//
//  DatabaseFileClassifier.swift
//  TablePro
//

import Darwin
import Foundation
import TableProUtilities

// Names the database type that wrote a file from its own bytes, reading only as far as the longest signature
// reaches. Anything that is not a regular file, is empty or cannot be read is unidentified, and the caller falls
// back to the extension.
internal enum DatabaseFileClassifier {
    internal enum Access: Sendable {
        // A file the user opened on purpose: a download or a slow volume is worth the wait.
        case mayWait
        // An open panel's enable filter, which AppKit calls on the main thread while the panel browses.
        case withoutWaiting
    }

    // A plugin declaring a signature deeper than this is not read at all rather than read in full.
    internal static let maximumPrefixLength = 64 * 1_024

    internal static func classify(_ url: URL, access: Access = .mayWait) -> DatabaseType? {
        classify(url, candidates: PluginMetadataRegistry.shared.allFileSignatures(), access: access)
    }

    internal static func classify(
        _ url: URL,
        candidates: [String: [DatabaseFileSignature]],
        access: Access = .mayWait
    ) -> DatabaseType? {
        guard url.isFileURL, !candidates.isEmpty else { return nil }
        let prefixLength = candidates.values
            .flatMap { $0 }
            .map(\.requiredPrefixLength)
            .max() ?? 0
        guard prefixLength > 0, prefixLength <= maximumPrefixLength else { return nil }
        switch access {
        case .mayWait:
            guard let size = regularFileSize(of: url), size > 0 else { return nil }
        case .withoutWaiting:
            guard isReadableWithoutWaiting(url) else { return nil }
        }
        guard let prefix = readPrefix(of: url, length: prefixLength, access: access) else { return nil }

        // The longest match wins and the type id breaks a tie, so the answer never depends on dictionary order.
        let matches = candidates.flatMap { typeId, signatures in
            signatures.filter { $0.matches(prefix) }.map { (typeId: typeId, weight: $0.totalMarkerLength) }
        }
        let winner = matches.max { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.typeId > rhs.typeId : lhs.weight < rhs.weight
        }
        return winner.map { DatabaseType(rawValue: $0.typeId) }
    }

    // From metadata alone: a non-empty regular file on this Mac's own disk whose bytes are already here. A pipe, a
    // socket or a device blocks in open, a network volume takes as long as the network, and an iCloud or File
    // Provider file that is not downloaded waits for the download.
    internal static func isReadableWithoutWaiting(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .volumeIsLocalKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.volumeIsLocal == true,
              (values.fileSize ?? 0) > 0
        else { return false }
        if let status = values.ubiquitousItemDownloadingStatus, status != .current { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) == 0
    }

    // A dataless file opened here fails with EDEADLK instead of starting a download, even one that turned dataless
    // after the metadata was read.
    internal static func withoutMaterializing<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let changed = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
        defer {
            if changed, previous >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return try body()
    }

    private static func regularFileSize(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    // O_NONBLOCK keeps open from waiting on a pipe swapped in after the metadata was read; fstat then refuses it.
    private static func readPrefix(of url: URL, length: Int, access: Access) -> [UInt8]? {
        let read = { () -> [UInt8]? in
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            var filled = 0
            while filled < length {
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return 0 }
                    return Darwin.read(descriptor, base.advanced(by: filled), length - filled)
                }
                if count > 0 {
                    filled += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return filled > 0 ? Array(buffer.prefix(filled)) : nil
        }
        switch access {
        case .mayWait: return read()
        case .withoutWaiting: return withoutMaterializing(read)
        }
    }
}
