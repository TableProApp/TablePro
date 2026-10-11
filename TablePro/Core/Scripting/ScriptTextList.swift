//
//  ScriptTextList.swift
//  TablePro
//

import Foundation

/// A `list of text` property value. `NSArray` does not implement `scriptingContains:`, so a plain
/// array makes `every connection whose tags contains "x"` match nothing.
@objc(TPScriptTextList)
internal final class ScriptTextList: NSArray {
    private let items: [String]

    internal init(_ items: [String]) {
        self.items = items
        super.init()
    }

    override internal convenience init() {
        self.init([])
    }

    override internal convenience init(objects: UnsafePointer<AnyObject>?, count: Int) {
        let buffer = UnsafeBufferPointer(start: objects, count: objects == nil ? 0 : count)
        self.init(buffer.compactMap { $0 as? String })
    }

    internal required init?(coder: NSCoder) {
        nil
    }

    override internal var count: Int {
        items.count
    }

    override internal func object(at index: Int) -> Any {
        items[index]
    }

    /// AppleScript's own `contains` on a list: one item matches a member, a list matches a run of
    /// members in order. Text compares ignoring case, as AppleScript does by default.
    override internal func scriptingContains(_ object: Any) -> Bool {
        let wanted: [String]
        if let list = object as? [Any] {
            let strings = list.compactMap { $0 as? String }
            guard strings.count == list.count else { return false }
            wanted = strings
        } else if let text = object as? String {
            wanted = [text]
        } else {
            return false
        }
        guard !wanted.isEmpty else { return true }
        guard wanted.count <= items.count else { return false }
        return (0 ... items.count - wanted.count).contains { start in
            zip(items[start...], wanted).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        }
    }
}
