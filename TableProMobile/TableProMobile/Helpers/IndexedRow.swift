import Foundation

/// Identifiable wrapper used by iOS lists that need both the row payload and
/// its position index. Iterating over `[IndexedRow]` instead of
/// `rows.indices` keeps SwiftUI's `ForEach` diff stable when the underlying
/// `[[String?]]` shrinks mid-render — the pattern that caused the
/// `Array._checkSubscript` crashes in release 1.0 (build 11).
struct IndexedRow: Identifiable {
    let id: Int
    let values: [String?]

    static func wrap(_ rows: [[String?]]) -> [IndexedRow] {
        rows.enumerated().map { IndexedRow(id: $0.offset, values: $0.element) }
    }
}
