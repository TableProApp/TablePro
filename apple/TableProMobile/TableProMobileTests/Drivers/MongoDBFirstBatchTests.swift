import Foundation
@testable import TableProMobile
import TableProPluginKit
import Testing

struct MongoDBFirstBatchTests {
    private func sentBatchSize(_ options: MongoScriptCursorOptions, ceiling: Int) throws -> Int? {
        let json = options.findOptionsJson(limit: ceiling, timeoutMS: 0)
        let document = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return document["batchSize"] as? Int
    }

    @Test("A page asks for one document past its limit, so the first batch closes the cursor")
    func pageFitsTheFirstBatch() throws {
        #expect(try sentBatchSize(.none, ceiling: 1_001) == 1_002)
    }

    @Test("A limit under the row cap sizes the batch")
    func scriptLimitSizesTheBatch() throws {
        var options = MongoScriptCursorOptions.none
        options.limit = 20
        #expect(try sentBatchSize(options, ceiling: 1_001) == 21)
    }

    @Test("A batch size the script set is sent as written", arguments: [0, 5, 1_001])
    func scriptBatchSizeIsKept(batchSize: Int) throws {
        var options = MongoScriptCursorOptions.none
        options.batchSize = batchSize
        #expect(try sentBatchSize(options, ceiling: 1_001) == batchSize)
    }

    @Test("A read with no row cap keeps the server's default batch")
    func uncappedReadKeepsTheDefaultBatch() throws {
        #expect(try sentBatchSize(.none, ceiling: PluginRowLimits.emergencyMax) == nil)
    }

    @Test("A limit of nothing has no first batch to size", arguments: [0, -1])
    func noLimitNoBatchSize(limit: Int) {
        #expect(MongoDBFindLimitPolicy.firstBatchSize(limit: limit) == nil)
    }

    @Test("The largest capped limit still gets a batch size")
    func largestCappedLimit() {
        let limit = PluginRowLimits.emergencyMax - 1
        #expect(MongoDBFindLimitPolicy.firstBatchSize(limit: limit) == PluginRowLimits.emergencyMax)
    }
}
