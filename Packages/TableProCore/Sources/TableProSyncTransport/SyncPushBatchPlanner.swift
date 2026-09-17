import Foundation

public struct SyncPushBatchPlan: Equatable, Sendable {
    public let saves: Range<Int>
    public let deletions: Range<Int>

    public init(saves: Range<Int>, deletions: Range<Int>) {
        self.saves = saves
        self.deletions = deletions
    }

    public var itemCount: Int { saves.count + deletions.count }
    public var isEmpty: Bool { itemCount == 0 }
}

public enum SyncPushBatchPlanner {
    public static let serverItemLimit = 250

    public static func plans(
        saveCount: Int,
        deletionCount: Int,
        limit: Int = serverItemLimit
    ) -> [SyncPushBatchPlan] {
        let perBatch = max(1, limit)
        var plans: [SyncPushBatchPlan] = []
        var saveIndex = 0
        var deletionIndex = 0

        while saveIndex < saveCount || deletionIndex < deletionCount {
            let saves = min(saveCount - saveIndex, perBatch)
            let deletions = min(deletionCount - deletionIndex, perBatch - saves)
            plans.append(SyncPushBatchPlan(
                saves: saveIndex..<(saveIndex + saves),
                deletions: deletionIndex..<(deletionIndex + deletions)
            ))
            saveIndex += saves
            deletionIndex += deletions
        }

        return plans
    }

    public static func halves(of plan: SyncPushBatchPlan) -> [SyncPushBatchPlan] {
        guard plan.itemCount > 1 else { return [] }

        let midpoint = plan.itemCount / 2
        let leadingSaves = min(midpoint, plan.saves.count)
        let leadingDeletions = midpoint - leadingSaves
        let saveSplit = plan.saves.lowerBound + leadingSaves
        let deletionSplit = plan.deletions.lowerBound + leadingDeletions

        return [
            SyncPushBatchPlan(
                saves: plan.saves.lowerBound..<saveSplit,
                deletions: plan.deletions.lowerBound..<deletionSplit
            ),
            SyncPushBatchPlan(
                saves: saveSplit..<plan.saves.upperBound,
                deletions: deletionSplit..<plan.deletions.upperBound
            ),
        ]
    }
}
