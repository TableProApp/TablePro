import Foundation

public enum SidebarNameMatchTier: Int, Comparable {
    case exact
    case prefix
    case substring

    public static func < (lhs: SidebarNameMatchTier, rhs: SidebarNameMatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// Trimmed once for a whole pass over the names, not once per name.
public struct SidebarNameQuery: Equatable, Sendable {
    public let text: String

    public init(_ query: String) {
        self.text = query.trimmingCharacters(in: .whitespaces)
    }

    public var isEmpty: Bool {
        text.isEmpty
    }

    public func tier(of candidate: String) -> SidebarNameMatchTier? {
        guard !text.isEmpty else { return .exact }
        let candidateString = candidate as NSString
        let range = candidateString.localizedStandardRange(of: text)
        guard range.location != NSNotFound else { return nil }
        guard range.location == 0 else { return .substring }
        return range.length == candidateString.length ? .exact : .prefix
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
