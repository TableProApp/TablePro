//
//  FileTextLoader.swift
//  TablePro
//

import Foundation

internal enum FileTextLoader {
    struct LoadedText {
        let content: String
        let encoding: String.Encoding
        /// When the file was last written, as of just before this text was read.
        ///
        /// Read here rather than by the caller, because a caller that stats afterwards records a
        /// date newer than the text it is holding, and a write that lands in between is then
        /// invisible: the tab looks up to date against a file it never read. Taking the date first
        /// fails the other way, leaving the baseline older than the text, so the changed-on-disk
        /// notice can fire once too often but never go missing.
        let modifiedAt: Date?
        var isUTF8: Bool { encoding == .utf8 }
    }

    static func load(_ url: URL) -> LoadedText? {
        let modifiedAt = modificationDate(of: url)
        var detected: String.Encoding = .utf8
        if let content = try? String(contentsOf: url, usedEncoding: &detected) {
            return LoadedText(content: content, encoding: detected, modifiedAt: modifiedAt)
        }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return LoadedText(content: content, encoding: .utf8, modifiedAt: modifiedAt)
        }
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            return LoadedText(content: content, encoding: .isoLatin1, modifiedAt: modifiedAt)
        }
        return nil
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    static func loadHeader(_ url: URL, maxBytes: Int = 4_096) -> LoadedText? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        let modifiedAt = modificationDate(of: url)

        if let content = String(data: data, encoding: .utf8) {
            return LoadedText(content: content, encoding: .utf8, modifiedAt: modifiedAt)
        }
        if let content = String(data: data, encoding: .isoLatin1) {
            return LoadedText(content: content, encoding: .isoLatin1, modifiedAt: modifiedAt)
        }
        return nil
    }
}

internal extension String.Encoding {
    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16BigEndian: return "UTF-16 BE"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf32: return "UTF-32"
        case .ascii: return "ASCII"
        case .isoLatin1: return "ISO Latin-1"
        case .isoLatin2: return "ISO Latin-2"
        case .windowsCP1250: return "Windows CP-1250"
        case .windowsCP1251: return "Windows CP-1251"
        case .windowsCP1252: return "Windows CP-1252"
        case .macOSRoman: return "Mac OS Roman"
        default: return "Encoding \(rawValue)"
        }
    }

    var ianaName: String {
        let cfEnc = CFStringConvertNSStringEncodingToEncoding(rawValue)
        if let name = CFStringConvertEncodingToIANACharSetName(cfEnc) as String? {
            return name
        }
        return displayName
    }
}
