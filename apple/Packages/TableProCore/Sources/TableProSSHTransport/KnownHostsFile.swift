import Foundation

// The apps' own known_hosts, one `[host]:port keyType base64` entry per line. Lines are written back as they were
// read, so a rewrite never drops one this build cannot parse.
public struct KnownHostsFile: Sendable {
    public struct Entry: Sendable, Equatable {
        public let host: String
        public let keyType: String
        public let keyData: Data

        public init(host: String, keyType: String, keyData: Data) {
            self.host = host
            self.keyType = keyType
            self.keyData = keyData
        }
    }

    public enum Match: Sendable, Equatable {
        case trusted
        case unknown
        case changed(storedKey: Data)
        // A line names the host but its key cannot be parsed, so the host is not new.
        case unreadable
    }

    private struct Line: Sendable {
        let text: String
        let host: String?
        let entry: Entry?
    }

    private var lines: [Line]

    public init() {
        lines = []
    }

    public init(contents: String) {
        lines = contents.components(separatedBy: "\n").compactMap(Self.line)
    }

    // Only a missing file reads as empty: after any other failure every stored host would look new.
    public static func load(from url: URL) throws -> KnownHostsFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return KnownHostsFile()
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return KnownHostsFile(contents: contents)
    }

    public var entries: [Entry] {
        lines.compactMap(\.entry)
    }

    public var contents: String {
        lines.isEmpty ? "" : lines.map(\.text).joined(separator: "\n") + "\n"
    }

    public func match(host: String, keyType: String, keyData: Data) -> Match {
        let named = lines.filter { $0.host == host }
        let stored = named.compactMap(\.entry)
        if stored.contains(where: { $0.keyData == keyData }) {
            return .trusted
        }
        if let previous = stored.first(where: { $0.keyType == keyType }) ?? stored.first {
            return .changed(storedKey: previous.keyData)
        }
        return named.isEmpty ? .unknown : .unreadable
    }

    public mutating func trust(host: String, keyType: String, keyData: Data) {
        lines.removeAll { $0.entry?.host == host && $0.entry?.keyType == keyType }
        lines.append(Line(
            text: "\(host) \(keyType) \(keyData.base64EncodedString())",
            host: host,
            entry: Entry(host: host, keyType: keyType, keyData: keyData)
        ))
    }

    @discardableResult
    public mutating func remove(host: String) -> Bool {
        let countBefore = lines.count
        lines.removeAll { $0.host == host }
        return lines.count < countBefore
    }

    private static func line(_ text: String) -> Line? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("#") else { return Line(text: text, host: nil, entry: nil) }

        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let host = fields[0]
        // Anything after the key is a comment, as in OpenSSH.
        guard fields.count >= 3, let keyData = Data(base64Encoded: fields[2]) else {
            return Line(text: text, host: host, entry: nil)
        }
        return Line(text: text, host: host, entry: Entry(host: host, keyType: fields[1], keyData: keyData))
    }
}
