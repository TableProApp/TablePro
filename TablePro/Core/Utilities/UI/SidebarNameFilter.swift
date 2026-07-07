//
//  SidebarNameFilter.swift
//  TablePro
//

import Foundation

internal enum SidebarNameMatchTier: Int, Comparable {
    case exact
    case prefix
    case substring

    static func < (lhs: SidebarNameMatchTier, rhs: SidebarNameMatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

internal enum SidebarNameFilter {
    static func matches(query: String, candidate: String) -> Bool {
        tier(query: query, candidate: candidate) != nil
    }

    static func tier(query: String, candidate: String) -> SidebarNameMatchTier? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .exact }
        let candidateString = candidate as NSString
        let range = candidateString.localizedStandardRange(of: trimmed)
        guard range.location != NSNotFound else { return nil }
        guard range.location == 0 else { return .substring }
        return range.length == candidateString.length ? .exact : .prefix
    }

    static func ranked<Element>(_ items: [Element], query: String, name: (Element) -> String) -> [Element] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, element -> (element: Element, tier: SidebarNameMatchTier, index: Int)? in
            guard let tier = tier(query: trimmed, candidate: name(element)) else { return nil }
            return (element, tier, index)
        }
        return scored
            .sorted { lhs, rhs in
                lhs.tier != rhs.tier ? lhs.tier < rhs.tier : lhs.index < rhs.index
            }
            .map(\.element)
    }
}
