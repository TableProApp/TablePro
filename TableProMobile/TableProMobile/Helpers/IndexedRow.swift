import Foundation

/// Identifiable wrapper used by iOS lists that need both the row payload and
/// its position index. Iterating over `[IndexedRow]` instead of
/// `rows.indices` keeps SwiftUI's `ForEach` diff stable when the underlying
/// row collection shrinks mid-render. This is the pattern that prevents the
/// `Array._checkSubscript` crashes seen in release 1.0 (build 11).
struct IndexedRow<Element>: Identifiable {
    let id: Int
    let values: Element

    static func wrap(_ rows: [Element]) -> [IndexedRow<Element>] {
        rows.enumerated().map { IndexedRow(id: $0.offset, values: $0.element) }
    }
}
