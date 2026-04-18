//
//  PluginExportUtilities.swift
//  TableProPluginKit
//

import Foundation

public enum PluginExportUtilities {
    public static func escapeJSONString(_ string: String) -> String {
        var utf8Result = [UInt8]()
        utf8Result.reserveCapacity(string.utf8.count)

        for byte in string.utf8 {
            switch byte {
            case 0x22: // "
                utf8Result.append(0x5C)
                utf8Result.append(0x22)
            case 0x5C: // backslash
                utf8Result.append(0x5C)
                utf8Result.append(0x5C)
            case 0x0A: // \n
                utf8Result.append(0x5C)
                utf8Result.append(0x6E)
            case 0x0D: // \r
                utf8Result.append(0x5C)
                utf8Result.append(0x72)
            case 0x09: // \t
                utf8Result.append(0x5C)
                utf8Result.append(0x74)
            case 0x08: // backspace
                utf8Result.append(0x5C)
                utf8Result.append(0x62)
            case 0x0C: // form feed
                utf8Result.append(0x5C)
                utf8Result.append(0x66)
            case 0x00...0x1F:
                let hex = String(format: "\\u%04X", byte)
                utf8Result.append(contentsOf: hex.utf8)
            default:
                utf8Result.append(byte)
            }
        }

        return String(bytes: utf8Result, encoding: .utf8) ?? string
    }

    @available(*, deprecated, message: "Use beginAtomicWrite(for:) for crash-safe writes")
    public static func createFileHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw PluginExportError.fileWriteFailed(url.path(percentEncoded: false))
        }
        return try FileHandle(forWritingTo: url)
    }

    public static func beginAtomicWrite(for destination: URL) throws -> (FileHandle, URL) {
        let tempURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil) else {
            throw PluginExportError.fileWriteFailed(destination.path(percentEncoded: false))
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        return (handle, tempURL)
    }

    public static func commitAtomicWrite(from tempURL: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
    }

    public static func rollbackAtomicWrite(at tempURL: URL) {
        try? FileManager.default.removeItem(at: tempURL)
    }

    public static func sanitizeForSQLComment(_ name: String) -> String {
        var result = name
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")
        result = result.replacingOccurrences(of: "/*", with: "")
        result = result.replacingOccurrences(of: "*/", with: "")
        result = result.replacingOccurrences(of: "--", with: "")
        return result
    }
}

public extension String {
    func toUTF8Data() throws -> Data {
        guard let data = self.data(using: .utf8) else {
            throw PluginExportError.encodingFailed
        }
        return data
    }
}
