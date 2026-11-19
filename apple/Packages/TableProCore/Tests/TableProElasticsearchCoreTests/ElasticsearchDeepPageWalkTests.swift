import TableProElasticsearchCore
import Testing

private struct WalkOutcome {
    let page: [Int]
    let batchesWithDocuments: [Bool]
}

// An index of `total` hits, read the way the driver reads it. A hit read without documents is -1,
// so a page that kept one shows it.
private func walk(total: Int, from: Int, size: Int, batchSize: Int) -> WalkOutcome {
    var walk = ElasticsearchDeepPageWalk<Int>(from: from, size: size, batchSize: batchSize)
    var position = 0
    var batches: [Bool] = []
    while !walk.isFinished {
        let withDocuments = walk.nextBatchNeedsDocuments
        batches.append(withDocuments)
        let end = min(position + batchSize, total)
        walk.absorb((position ..< end).map { withDocuments ? $0 : -1 })
        position = end
    }
    return WalkOutcome(page: walk.page, batchesWithDocuments: batches)
}

struct ElasticsearchDeepPageWalkTests {
    @Test("Batches wholly before the page are read without documents")
    func skippedBatchesCarryNoDocuments() {
        let outcome = walk(total: 200_000, from: 100_000, size: 1_000, batchSize: 1_000)
        #expect(outcome.batchesWithDocuments == Array(repeating: false, count: 100) + [true])
        #expect(outcome.page == Array(100_000 ..< 101_000))
    }

    @Test("A batch the page starts inside is read with documents")
    func batchHoldingThePageStartCarriesDocuments() {
        let outcome = walk(total: 5_000, from: 1_500, size: 1_000, batchSize: 1_000)
        #expect(outcome.batchesWithDocuments == [false, true, true])
        #expect(outcome.page == Array(1_500 ..< 2_500))
    }

    @Test("A page starting on the last hit of a batch still reads that batch with documents")
    func pageStartingOnTheLastHitOfABatch() {
        let outcome = walk(total: 5_000, from: 999, size: 2, batchSize: 1_000)
        #expect(outcome.batchesWithDocuments == [true, true])
        #expect(outcome.page == [999, 1_000])
    }

    @Test("A page starting right after a batch skips that whole batch")
    func pageStartingOnABatchBoundary() {
        let outcome = walk(total: 5_000, from: 1_000, size: 2, batchSize: 1_000)
        #expect(outcome.batchesWithDocuments == [false, true])
        #expect(outcome.page == [1_000, 1_001])
    }

    @Test("An index that ends before the page gives an empty page")
    func indexEndingBeforeThePage() {
        let outcome = walk(total: 1_500, from: 100_000, size: 1_000, batchSize: 1_000)
        #expect(outcome.page.isEmpty)
        #expect(outcome.batchesWithDocuments.count == 2)
    }

    @Test("An index that ends inside the page gives the hits it has")
    func indexEndingInsideThePage() {
        let outcome = walk(total: 10_500, from: 10_000, size: 1_000, batchSize: 1_000)
        #expect(outcome.page == Array(10_000 ..< 10_500))
    }

    @Test("A page of no rows reads nothing")
    func emptyPageReadsNothing() {
        let outcome = walk(total: 5_000, from: 10_000, size: 0, batchSize: 1_000)
        #expect(outcome.batchesWithDocuments.isEmpty)
    }
}
