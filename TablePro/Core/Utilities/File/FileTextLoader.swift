//
//  FileTextLoader.swift
//  TablePro
//

import Foundation

internal enum FileTextLoader {
    struct LoadedText: Sendable {
        let content: String
        let textEncoding: FileTextEncoding
        /// What the file was, as of just before this text was read.
        ///
        /// Read here rather than by the caller, because a caller that stats afterwards records a
        /// stamp newer than the text it is holding, and a write that lands in between is then
        /// invisible: the tab looks up to date against a file it never read. Taking the stamp first
        /// fails the other way, leaving the baseline older than the text, so the changed-on-disk
        /// notice can fire once too often but never go missing.
        let stamp: FileStamp?
        var encoding: String.Encoding { textEncoding.encoding }
        var isUTF8: Bool { encoding == .utf8 }
    }

    static func load(_ url: URL) -> LoadedText? {
        try? read(url)
    }

    static func read(_ url: URL) throws -> LoadedText {
        let stamp = FileStamp.read(url)
        if startsWithByteOrderMark(url) {
            return try readByteOrderMarked(url, stamp: stamp)
        }
        let attribute = TextEncodingAttribute.read(from: url)
        var detected: String.Encoding = .utf8
        if let content = try? String(contentsOf: url, usedEncoding: &detected) {
            let textEncoding = FileTextEncoding(encoding: detected, attributeOnDisk: attribute)
            return LoadedText(content: content, textEncoding: textEncoding, stamp: stamp)
        }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return LoadedText(content: content, textEncoding: .utf8, stamp: stamp)
        }
        let content = try String(contentsOf: url, encoding: .isoLatin1)
        return LoadedText(content: content, textEncoding: FileTextEncoding(encoding: .isoLatin1), stamp: stamp)
    }

    static func decode(_ data: Data, declaredEncoding: String.Encoding? = nil) -> String? {
        if declaredEncoding != nil, ByteOrderMark.leading(data) == nil, let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        guard !data.isEmpty else { return "" }
        return TextPrefixDecoder.decode(data, prefixLength: data.count, declaredEncoding: declaredEncoding)?.content
    }

    static func loadHeader(_ url: URL, maxBytes: Int = 4_096) -> LoadedText? {
        let stamp = FileStamp.read(url)
        let attribute = TextEncodingAttribute.read(from: url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: maxBytes + TextPrefixDecoder.lookaheadLength),
              let decoded = TextPrefixDecoder.decode(
                  bytes,
                  prefixLength: maxBytes,
                  declaredEncoding: attribute?.encoding
              ) else { return nil }
        return LoadedText(
            content: decoded.content,
            textEncoding: textEncoding(of: decoded, attribute: attribute),
            stamp: stamp
        )
    }

    private static func startsWithByteOrderMark(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: ByteOrderMark.longestLength) else { return false }
        return ByteOrderMark.leading(bytes) != nil
    }

    private static func readByteOrderMarked(_ url: URL, stamp: FileStamp?) throws -> LoadedText {
        let bytes = try Data(contentsOf: url)
        guard let decoded = TextPrefixDecoder.decode(bytes, prefixLength: bytes.count) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return LoadedText(
            content: decoded.content,
            textEncoding: textEncoding(of: decoded, attribute: nil),
            stamp: stamp
        )
    }

    private static func textEncoding(
        of decoded: TextPrefixDecoder.Decoded,
        attribute: TextEncodingAttribute?
    ) -> FileTextEncoding {
        FileTextEncoding(encoding: decoded.encoding, byteOrderMark: decoded.byteOrderMark, attributeOnDisk: attribute)
    }
}

internal extension String.Encoding {
    init?(coreFoundationEncoding: CFStringEncoding) {
        guard coreFoundationEncoding != kCFStringEncodingInvalidId,
              CFStringIsEncodingAvailable(coreFoundationEncoding) else { return nil }
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(coreFoundationEncoding))
    }

    init?(ianaCharacterSetName name: String) {
        self.init(coreFoundationEncoding: CFStringConvertIANACharSetNameToEncoding(name as CFString))
    }

    private static let gb18030 = String.Encoding(
        coreFoundationEncoding: CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    )

    var representsAllOfUnicode: Bool {
        switch self {
        case .utf8, .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian:
            return true
        default:
            return self == Self.gb18030
        }
    }

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
