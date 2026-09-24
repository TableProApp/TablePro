//
//  WalkthroughApplyPlan.swift
//  TablePro
//

import Foundation

enum WalkthroughApplyPlan: Equatable {
    case replace(tabId: UUID, range: NSRange)
    case insertAsNewQuery

    static func resolve(beforeSQL: String, source: QueryEditorAnchor?, tabText: String?) -> WalkthroughApplyPlan {
        guard let source, let tabText, !beforeSQL.isEmpty else { return .insertAsNewQuery }
        let text = tabText as NSString

        if let range = source.range,
           range.location >= 0,
           NSMaxRange(range) <= text.length,
           text.substring(with: range) == beforeSQL {
            return .replace(tabId: source.tabId, range: range)
        }

        guard let unique = uniqueRange(of: beforeSQL, in: tabText) else { return .insertAsNewQuery }
        return .replace(tabId: source.tabId, range: unique)
    }

    static func uniqueRange(of fragment: String, in text: String) -> NSRange? {
        guard !fragment.isEmpty else { return nil }
        let source = text as NSString
        let first = source.range(of: fragment)
        guard first.location != NSNotFound else { return nil }
        let restStart = first.location + 1
        let rest = NSRange(location: restStart, length: source.length - restStart)
        return source.range(of: fragment, range: rest).location == NSNotFound ? first : nil
    }
}
