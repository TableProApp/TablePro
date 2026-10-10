import Foundation

extension ImportPlanner {
    struct SavedQueryPlan {
        var planned: [PlannedQuery] = []
        var statuses: [BundleRef: QueryStatus] = [:]
    }

    static func planSavedQueries(
        _ preview: ImportPreview,
        selection: ImportSelection,
        targets: [BundleRef: UUID]
    ) -> SavedQueryPlan {
        let bundle = preview.collected.bundle
        var sources: [BundleRef: BundleSavedQuery] = [:]
        for query in bundle.savedQueries where sources[query.ref] == nil {
            sources[query.ref] = query
        }

        let library = SavedQueryLedger(preview.library.savedQueries)
        var ledger = library
        var plan = SavedQueryPlan()
        for row in preview.queries {
            let scope: UUID?
            if let connection = row.connection {
                guard let target = targets[connection] else {
                    plan.statuses[row.ref] = unavailable(.connectionSkipped)
                    continue
                }
                scope = target
            } else {
                scope = nil
            }

            guard !row.isTooLarge, let source = sources[row.ref] else {
                plan.statuses[row.ref] = unavailable(.tooLarge)
                continue
            }

            switch ledger.verdict(name: row.name, sql: source.sql, keyword: row.keyword, scope: scope) {
            case .tooLarge:
                plan.statuses[row.ref] = unavailable(.tooLarge)
            case .alreadySaved:
                let savedHere = library.verdict(name: row.name, sql: source.sql, keyword: row.keyword, scope: scope)
                    == .alreadySaved
                plan.statuses[row.ref] = unavailable(savedHere ? .alreadySaved : .addedByAnotherRow)
            case .insert(let keyword, let dropped, let nameExists):
                let isIncluded = selection.wantsQuery(row)
                plan.statuses[row.ref] = QueryStatus(
                    availability: .available,
                    isIncluded: isIncluded,
                    nameExists: nameExists,
                    droppedKeyword: dropped
                )
                guard isIncluded else { continue }
                plan.planned.append(PlannedQuery(
                    ref: row.ref,
                    name: row.name,
                    sql: source.sql,
                    keyword: keyword,
                    connectionId: scope,
                    folderPath: folderPath(for: source, scope: scope, in: bundle, targets: targets)
                ))
                ledger.record(SavedQueryLedger.Entry(name: row.name, sql: source.sql, keyword: keyword, connectionId: scope))
            }
        }
        return plan
    }

    static func folderPath(
        for query: BundleSavedQuery,
        scope: UUID?,
        in bundle: ConnectionBundle,
        targets: [BundleRef: UUID]
    ) -> [PathComponent] {
        var path: [PathComponent] = []
        for folder in bundle.folderChain(query.folderRef) {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { break }
            let folderScope: UUID?
            if let connection = folder.connectionRef {
                guard let target = targets[connection] else { break }
                folderScope = target
            } else {
                folderScope = nil
            }
            if let parent = path.last, !SavedQueryScopeRule.folder(parent.scope, canHold: folderScope) {
                break
            }
            path.append(PathComponent(name: name, scope: folderScope, color: nil))
        }
        while let leaf = path.last, !SavedQueryScopeRule.folder(leaf.scope, canHold: scope) {
            path.removeLast()
        }
        return path
    }

    private static func unavailable(_ availability: QueryStatus.Availability) -> QueryStatus {
        QueryStatus(availability: availability, isIncluded: false, nameExists: false, droppedKeyword: nil)
    }
}
