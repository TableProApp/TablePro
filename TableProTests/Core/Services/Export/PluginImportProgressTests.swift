//
//  PluginImportProgressTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct PluginImportProgressTests {
    @Test("Exact total set once is reported as the estimated total")
    func exactTotalReported() {
        let progress = PluginImportProgress(progress: Progress(totalUnitCount: 0))
        progress.setEstimatedTotal(3_503)
        #expect(progress.estimatedTotalStatements == 3_503)
    }

    @Test("Batched increments accumulate the exact processed count without overshoot")
    func batchedIncrementsCountExactly() {
        let progress = PluginImportProgress(progress: Progress(totalUnitCount: 0))
        progress.setEstimatedTotal(3_503)
        for _ in 0..<7 { progress.incrementStatement(by: 500) }
        progress.incrementStatement(by: 3)
        #expect(progress.processedStatements == 3_503)
        #expect(progress.processedStatements == progress.estimatedTotalStatements)
    }

    @Test("finalize flushes the live completed count to the underlying Progress")
    func finalizeFlushesCount() {
        let nsProgress = Progress(totalUnitCount: 0)
        let progress = PluginImportProgress(progress: nsProgress)
        progress.setEstimatedTotal(10)
        progress.incrementStatement(by: 7)
        progress.finalize()
        #expect(nsProgress.completedUnitCount == 7)
    }
}
