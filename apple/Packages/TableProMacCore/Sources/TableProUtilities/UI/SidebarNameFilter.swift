import Foundation
import os

public enum SidebarNameMatchTier: Int, Comparable {
    case exact
    case prefix
    case substring

    public static func < (lhs: SidebarNameMatchTier, rhs: SidebarNameMatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// Trimmed and folded once for a whole pass over the names, not once per name.
public struct SidebarNameQuery: Equatable, Sendable {
    public let text: String
    // The query folded to lower-case ASCII bytes, when it is ASCII and the locale folds ASCII letters the way bytes do.
    // Nil sends every name to the locale-aware search.
    private let asciiNeedle: [UInt8]?

    public init(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        self.text = text
        self.asciiNeedle = text.utf8.allSatisfy { $0 < 0x80 } && AsciiFolding.matchesLocale()
            ? text.utf8.map(AsciiFolding.fold)
            : nil
    }

    public var isEmpty: Bool {
        text.isEmpty
    }

    public func tier(of candidate: String) -> SidebarNameMatchTier? {
        guard !text.isEmpty else { return .exact }
        if let asciiNeedle, let answer = AsciiFolding.tier(of: candidate, needle: asciiNeedle) {
            return answer.tier
        }
        let candidateString = candidate as NSString
        let range = candidateString.localizedStandardRange(of: text)
        guard range.location != NSNotFound else { return nil }
        guard range.location == 0 else { return .substring }
        return range.length == candidateString.length ? .exact : .prefix
    }
}

// An ASCII name against an ASCII query is a byte search: `localizedStandardRange` folds nothing there but case, and a
// catalog of 100,000 names costs it about 20 ms a key where bytes cost 2. Any other name takes the locale-aware search.
enum AsciiFolding {
    struct Answer {
        let tier: SidebarNameMatchTier?
    }

    static func fold(_ byte: UInt8) -> UInt8 {
        (byte &- 0x41) < 26 ? byte | 0x20 : byte
    }

    // Nil when the name is not ASCII, or its bytes are not contiguous, so the caller asks the locale.
    static func tier(of candidate: String, needle: [UInt8]) -> Answer? {
        candidate.utf8.withContiguousStorageIfAvailable { bytes -> Answer? in
            for byte in bytes where byte >= 0x80 { return nil }
            let count = needle.count
            guard count <= bytes.count else { return Answer(tier: nil) }
            var start = 0
            search: while start <= bytes.count - count {
                for offset in 0..<count where fold(bytes[start + offset]) != needle[offset] {
                    start += 1
                    continue search
                }
                guard start == 0 else { return Answer(tier: .substring) }
                return Answer(tier: count == bytes.count ? .exact : .prefix)
            }
            return Answer(tier: nil)
        } ?? nil
    }

    private static let verdicts = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    // Turkish folds `I` to a dotless `ı`, so there the byte search would match names the locale-aware one does not.
    // Asked of the current locale, the one `localizedStandardRange` searches in, and kept per locale.
    static func matchesLocale(_ locale: Locale = .current) -> Bool {
        let identifier = locale.identifier
        if let known = verdicts.withLock({ $0[identifier] }) { return known }
        let matches = (UInt8(ascii: "A")...UInt8(ascii: "Z")).allSatisfy { upper in
            let lower = String(UnicodeScalar(upper | 0x20))
            return String(UnicodeScalar(upper)).folding(options: .caseInsensitive, locale: locale) == lower
                && lower.folding(options: .caseInsensitive, locale: locale) == lower
        }
        verdicts.withLock { $0[identifier] = matches }
        return matches
    }
}

// Read back exact, prefix, substring: the stable sort by tier, without sorting.
public struct SidebarRankedMatches<Element> {
    private var exact: [Element] = []
    private var prefix: [Element] = []
    private var substring: [Element] = []

    public init() {}

    public mutating func append(_ element: Element, tier: SidebarNameMatchTier) {
        switch tier {
        case .exact: exact.append(element)
        case .prefix: prefix.append(element)
        case .substring: substring.append(element)
        }
    }

    public var elements: [Element] {
        exact + prefix + substring
    }
}

public enum SidebarNameFilter {
    public static func matches(query: String, candidate: String) -> Bool {
        tier(query: query, candidate: candidate) != nil
    }

    public static func tier(query: String, candidate: String) -> SidebarNameMatchTier? {
        SidebarNameQuery(query).tier(of: candidate)
    }

    public static func ranked<Element>(_ items: [Element], query: String, name: (Element) -> String) -> [Element] {
        ranked(items, query: SidebarNameQuery(query), name: name)
    }

    public static func ranked<Element>(
        _ items: [Element],
        query: SidebarNameQuery,
        name: (Element) -> String
    ) -> [Element] {
        guard !query.isEmpty else { return items }
        var matches = SidebarRankedMatches<Element>()
        for item in items {
            guard let tier = query.tier(of: name(item)) else { continue }
            matches.append(item, tier: tier)
        }
        return matches.elements
    }
}
