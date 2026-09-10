//
//  ZipReader.swift
//  XLSXImportPlugin
//

import Compression
import Foundation

/// Reads named entries out of a ZIP archive.
///
/// An `.xlsx` is a ZIP of XML parts, and only a few of them matter, so the whole archive is never
/// expanded: the central directory is parsed, and an entry is inflated on request.
///
/// Entries are found through the central directory rather than by scanning for local headers. The
/// local header is allowed to carry zero sizes and defer them to a data descriptor after the
/// compressed bytes, which is what Excel writes when it streams a sheet, and a scanner that trusts
/// the local header reads a zero-length sheet.
enum ZipReader {
    enum ZipError: LocalizedError {
        case notAZipArchive
        case entryNotFound(String)
        case unsupportedCompression(UInt16)
        case corruptEntry(String)

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                return String(localized: "That file is not a valid XLSX workbook.")
            case .entryNotFound(let name):
                return String(format: String(localized: "The workbook is missing %@."), name)
            case .unsupportedCompression(let method):
                return String(
                    format: String(localized: "The workbook uses compression method %d, which TablePro cannot read."),
                    Int(method))
            case .corruptEntry(let name):
                return String(format: String(localized: "Could not read %@ from the workbook."), name)
            }
        }
    }

    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// The archive's entries, keyed by path.
    static func entries(in data: Data) throws -> [String: Entry] {
        guard let directoryStart = endOfCentralDirectoryOffset(in: data) else {
            throw ZipError.notAZipArchive
        }
        var entries: [String: Entry] = [:]
        var cursor = directoryStart
        while cursor + 46 <= data.count, readUInt32(data, cursor) == 0x0201_4B50 {
            let method = readUInt16(data, cursor + 10)
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let uncompressedSize = Int(readUInt32(data, cursor + 24))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let offset = Int(readUInt32(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(
                decoding: data[data.startIndex + nameStart ..< data.startIndex + nameStart + nameLength],
                as: UTF8.self)
            entries[name] = Entry(
                path: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: offset
            )
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw ZipError.notAZipArchive }
        return entries
    }

    /// The bytes of one entry, inflated when it is deflated. Excel writes deflate; the writer in
    /// TablePro's own XLSX export stores entries uncompressed, and both have to read back.
    static func data(for entry: Entry, in archive: Data) throws -> Data {
        let base = archive.startIndex
        let headerStart = entry.localHeaderOffset
        guard headerStart + 30 <= archive.count,
              readUInt32(archive, headerStart) == 0x0403_4B50 else {
            throw ZipError.corruptEntry(entry.path)
        }
        let nameLength = Int(readUInt16(archive, headerStart + 26))
        let extraLength = Int(readUInt16(archive, headerStart + 28))
        let payloadStart = headerStart + 30 + nameLength + extraLength
        guard payloadStart + entry.compressedSize <= archive.count else {
            throw ZipError.corruptEntry(entry.path)
        }
        let payload = archive[base + payloadStart ..< base + payloadStart + entry.compressedSize]

        switch entry.compressionMethod {
        case 0:
            return Data(payload)
        case 8:
            guard let inflated = inflate(Data(payload), expectedSize: entry.uncompressedSize) else {
                throw ZipError.corruptEntry(entry.path)
            }
            return inflated
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    static func data(named path: String, in archive: Data) throws -> Data {
        let all = try entries(in: archive)
        guard let entry = all[path] else { throw ZipError.entryNotFound(path) }
        return try data(for: entry, in: archive)
    }

    // MARK: - Private

    /// `COMPRESSION_ZLIB` in the Compression framework is raw deflate, which is exactly what a ZIP
    /// entry holds: no zlib header, no trailer.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        /// A zero uncompressed size in the directory means the writer deferred it, so a capacity is
        /// guessed and grown rather than trusted.
        let capacity = expectedSize > 0 ? expectedSize : max(data.count * 8, 64 * 1_024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            /// A full buffer returns the capacity, which is indistinguishable from a truncated
            /// read, so an unknown size retries with more room rather than returning a short part.
            guard expectedSize <= 0, capacity < 64 * 1_024 * 1_024 else { return nil }
            return inflateGrowing(data, capacity: capacity * 4)
        }
        guard written < capacity || expectedSize > 0 else {
            return inflateGrowing(data, capacity: capacity * 4)
        }
        return output.prefix(written)
    }

    private static func inflateGrowing(_ data: Data, capacity: Int) -> Data? {
        guard capacity <= 256 * 1_024 * 1_024 else { return nil }
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        guard written < capacity else { return inflateGrowing(data, capacity: capacity * 4) }
        return output.prefix(written)
    }

    /// The end-of-central-directory record is at the tail, after a comment of up to 64 KB, so the
    /// last 64 KB plus the record size is scanned backwards for its signature.
    private static func endOfCentralDirectoryOffset(in data: Data) -> Int? {
        let minimumRecord = 22
        guard data.count >= minimumRecord else { return nil }
        let searchLimit = min(data.count, 64 * 1_024 + minimumRecord)
        let start = data.count - searchLimit
        var cursor = data.count - minimumRecord
        while cursor >= start {
            if readUInt32(data, cursor) == 0x0605_4B50 {
                return Int(readUInt32(data, cursor + 16))
            }
            cursor -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
