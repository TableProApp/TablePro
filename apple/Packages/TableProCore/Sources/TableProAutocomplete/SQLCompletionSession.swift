import Foundation

public struct SQLCompletionSession: Sendable {
    public let items: [SQLCompletionItem]
    // The wider ranked pool an open popup re-ranks while it stays open; `items` is the slice it shows.
    public let candidates: [SQLCompletionItem]
    public let context: SQLContext
    // More candidates matched than the pool holds, so a longer prefix can promote one the pool dropped.
    public let candidatesTruncated: Bool
}
