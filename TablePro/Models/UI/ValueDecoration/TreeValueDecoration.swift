//
//  TreeValueDecoration.swift
//  TablePro
//

import Foundation

/// sRGB components in 0...1. A plain value, because the classifier runs off the main thread and
/// `NSColor` is not `Sendable`.
internal struct RGBAColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

internal enum TreeValueDecoration: Equatable, Sendable {
    case none
    case link(URL)
    case color(RGBAColor)
}

internal enum TreeValueClassifier {
    /// Each check starts with its own length gate, so a long value costs two bounded counts.
    static func classify(_ raw: String) -> TreeValueDecoration {
        if let color = CSSColorParser.parse(raw) { return .color(color) }
        if let url = DataLinkPolicy.openableURL(from: raw) { return .link(url) }
        return .none
    }
}

internal extension String.UTF8View {
    /// `count` walks a bridged string to its end, about 1 ms per million characters. This stops
    /// one unit past the limit.
    func count(isAtMost limit: Int) -> Bool {
        index(startIndex, offsetBy: limit + 1, limitedBy: endIndex) == nil
    }
}

internal extension Unicode.Scalar {
    /// `String.lowercased()` maps some non-ASCII letters onto ASCII ones (the Kelvin sign becomes
    /// `k`), which would let them through a keyword match.
    var asciiLowercased: Unicode.Scalar {
        ("A"..."Z").contains(self) ? Unicode.Scalar(UInt8(ascii: self) | 0x20) : self
    }
}
