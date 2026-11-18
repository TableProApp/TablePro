// A page past max_result_window has no offset to jump to, so every hit before it is walked with search_after.
public struct ElasticsearchDeepPageWalk<Hit> {
    public private(set) var page: [Hit] = []
    public private(set) var isFinished: Bool
    private var hitsLeftToSkip: Int
    private let size: Int
    private let batchSize: Int

    public init(from: Int, size: Int, batchSize: Int) {
        hitsLeftToSkip = max(0, from)
        self.size = size
        self.batchSize = batchSize
        isFinished = size <= 0
    }

    // A batch that ends before the page starts is read for its sort values alone.
    public var nextBatchNeedsDocuments: Bool { hitsLeftToSkip < batchSize }

    public mutating func absorb(_ hits: [Hit]) {
        let skipped = min(hitsLeftToSkip, hits.count)
        hitsLeftToSkip -= skipped
        page.append(contentsOf: hits.dropFirst(skipped).prefix(size - page.count))
        if page.count >= size || hits.count < batchSize { isFinished = true }
    }
}
