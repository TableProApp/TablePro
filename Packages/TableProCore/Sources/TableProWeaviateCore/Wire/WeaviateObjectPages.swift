import Foundation

public struct WeaviateObjectPages: AsyncSequence, Sendable {
    public typealias Element = [WeaviateObject]

    private let client: WeaviateClient
    private let collection: String
    private let pageSize: Int
    private let includeVector: Bool

    init(client: WeaviateClient, collection: String, pageSize: Int, includeVector: Bool) {
        self.client = client
        self.collection = collection
        self.pageSize = Swift.max(pageSize, 1)
        self.includeVector = includeVector
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(pages: self)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let pages: WeaviateObjectPages
        private var cursor: String?
        private var isExhausted = false

        init(pages: WeaviateObjectPages) {
            self.pages = pages
        }

        public mutating func next() async throws -> [WeaviateObject]? {
            guard !isExhausted else { return nil }
            try Task.checkCancellation()
            let page = try await pages.client.objects(
                collection: pages.collection,
                limit: pages.pageSize,
                after: cursor,
                includeVector: pages.includeVector
            )
            isExhausted = page.count < pages.pageSize
            guard !page.isEmpty else { return nil }
            if !isExhausted {
                cursor = try nextCursor(after: page)
            }
            return page
        }

        private func nextCursor(after page: [WeaviateObject]) throws -> String {
            guard let last = page.last?.uuid, !last.isEmpty else {
                throw WeaviateError.malformedResponse(String(
                    format: String(localized: "Weaviate returned an object of %@ without an id, so the rest of the collection cannot be read."),
                    pages.collection
                ))
            }
            guard last != cursor else {
                throw WeaviateError.malformedResponse(String(
                    format: String(localized: "Weaviate returned the same page of %@ twice. Reading a whole collection needs Weaviate 1.18 or later."),
                    pages.collection
                ))
            }
            return last
        }
    }
}

public extension WeaviateClient {
    func objectPages(
        collection: String,
        pageSize: Int,
        includeVector: Bool = true
    ) -> WeaviateObjectPages {
        WeaviateObjectPages(client: self, collection: collection, pageSize: pageSize, includeVector: includeVector)
    }
}
