import Foundation

/// Lines a session printed on the server since they were last read, such as Oracle's `DBMS_OUTPUT`.
public struct PluginServerOutput: Sendable, Equatable {
    public let lines: [String]

    /// Whether the session printed more than the driver read. The rest is gone, not waiting for the next read.
    public let isTruncated: Bool

    public static let none = PluginServerOutput(lines: [], isTruncated: false)

    public init(lines: [String], isTruncated: Bool) {
        self.lines = lines
        self.isTruncated = isTruncated
    }

    public var isEmpty: Bool {
        lines.isEmpty && !isTruncated
    }
}
