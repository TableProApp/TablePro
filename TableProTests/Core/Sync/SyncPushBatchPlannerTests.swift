//
//  SyncPushBatchPlannerTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProSyncTransport

@Suite("Sync push batch planner")
struct SyncPushBatchPlannerTests {
    @Test("The default limit is the server's documented 250 items per request")
    func defaultLimitMatchesServer() {
        #expect(SyncPushBatchPlanner.serverItemLimit == 250)
    }

    @Test("251 saves are sent as two requests")
    func savesAboveTheLimitSplit() {
        let plans = SyncPushBatchPlanner.plans(saveCount: 251, deletionCount: 0)

        #expect(plans.count == 2)
        #expect(plans[0] == SyncPushBatchPlan(saves: 0..<250, deletions: 0..<0))
        #expect(plans[1] == SyncPushBatchPlan(saves: 250..<251, deletions: 0..<0))
    }

    @Test("Saves and deletions share one request budget")
    func savesAndDeletionsShareTheLimit() {
        let plans = SyncPushBatchPlanner.plans(saveCount: 200, deletionCount: 100)

        #expect(plans.count == 2)
        #expect(plans[0].itemCount == 250)
        #expect(plans[0] == SyncPushBatchPlan(saves: 0..<200, deletions: 0..<50))
        #expect(plans[1] == SyncPushBatchPlan(saves: 200..<200, deletions: 50..<100))
    }

    @Test("Every plan stays within the limit and covers every item exactly once")
    func plansCoverEveryItem() {
        let cases: [(saves: Int, deletions: Int)] = [
            (0, 0), (1, 0), (0, 1), (250, 0), (0, 250), (251, 251), (999, 3), (3, 999), (1000, 1000),
        ]

        for testCase in cases {
            let plans = SyncPushBatchPlanner.plans(
                saveCount: testCase.saves,
                deletionCount: testCase.deletions
            )

            for plan in plans {
                #expect(plan.itemCount <= SyncPushBatchPlanner.serverItemLimit, "\(testCase)")
                #expect(plan.itemCount > 0, "\(testCase)")
            }
            #expect(plans.map(\.saves.count).reduce(0, +) == testCase.saves, "\(testCase)")
            #expect(plans.map(\.deletions.count).reduce(0, +) == testCase.deletions, "\(testCase)")
            #expect(contiguous(plans.map(\.saves), count: testCase.saves), "\(testCase)")
            #expect(contiguous(plans.map(\.deletions), count: testCase.deletions), "\(testCase)")
        }
    }

    @Test("A limit below one still terminates")
    func degenerateLimitTerminates() {
        let plans = SyncPushBatchPlanner.plans(saveCount: 3, deletionCount: 0, limit: 0)

        #expect(plans.count == 3)
        #expect(plans.allSatisfy { $0.itemCount == 1 })
    }

    @Test("Halving a refused batch produces two strictly smaller halves that cover it")
    func halvesCoverTheBatch() {
        let plan = SyncPushBatchPlan(saves: 0..<200, deletions: 50..<100)
        let halves = SyncPushBatchPlanner.halves(of: plan)

        #expect(halves.count == 2)
        #expect(halves[0].itemCount + halves[1].itemCount == plan.itemCount)
        #expect(halves.allSatisfy { $0.itemCount < plan.itemCount })
        #expect(halves[0].saves.lowerBound == plan.saves.lowerBound)
        #expect(halves[1].saves.upperBound == plan.saves.upperBound)
        #expect(halves[0].deletions.lowerBound == plan.deletions.lowerBound)
        #expect(halves[1].deletions.upperBound == plan.deletions.upperBound)
    }

    @Test("A batch holding one save and one deletion halves into one of each")
    func halvesSplitAcrossKinds() {
        let halves = SyncPushBatchPlanner.halves(of: SyncPushBatchPlan(saves: 4..<5, deletions: 7..<8))

        #expect(halves.count == 2)
        #expect(halves[0] == SyncPushBatchPlan(saves: 4..<5, deletions: 7..<7))
        #expect(halves[1] == SyncPushBatchPlan(saves: 5..<5, deletions: 7..<8))
    }

    @Test("A single item cannot be halved, so the caller rethrows instead of looping")
    func singleItemDoesNotHalve() {
        #expect(SyncPushBatchPlanner.halves(of: SyncPushBatchPlan(saves: 0..<1, deletions: 0..<0)).isEmpty)
        #expect(SyncPushBatchPlanner.halves(of: SyncPushBatchPlan(saves: 0..<0, deletions: 0..<1)).isEmpty)
        #expect(SyncPushBatchPlanner.halves(of: SyncPushBatchPlan(saves: 0..<0, deletions: 0..<0)).isEmpty)
    }

    @Test("Repeated halving reaches single items without losing any")
    func repeatedHalvingTerminates() {
        var queue = [SyncPushBatchPlan(saves: 0..<130, deletions: 0..<120)]
        var singles: [SyncPushBatchPlan] = []

        while let plan = queue.popLast() {
            let halves = SyncPushBatchPlanner.halves(of: plan)
            if halves.isEmpty {
                singles.append(plan)
                continue
            }
            queue.append(contentsOf: halves)
        }

        #expect(singles.map(\.itemCount).reduce(0, +) == 250)
        #expect(singles.allSatisfy { $0.itemCount == 1 })
    }

    private func contiguous(_ ranges: [Range<Int>], count: Int) -> Bool {
        var next = 0
        for range in ranges where !range.isEmpty {
            guard range.lowerBound == next else { return false }
            next = range.upperBound
        }
        return next == count
    }
}
