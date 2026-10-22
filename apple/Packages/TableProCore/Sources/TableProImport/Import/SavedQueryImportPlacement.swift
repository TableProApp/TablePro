import Foundation

public enum SavedQueryImportPlacement {
    public static func holdableFolderPath(_ path: [PathComponent], for scope: UUID?) -> [PathComponent] {
        var kept: [PathComponent] = []
        for component in path {
            guard !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  SavedQueryScopeRule.folder(kept.last?.scope, canHold: component.scope)
            else { break }
            kept.append(component)
        }
        while let leaf = kept.last, !SavedQueryScopeRule.folder(leaf.scope, canHold: scope) {
            kept.removeLast()
        }
        return kept
    }

    public static func importedName(_ query: PlannedQuery) -> String {
        let trimmed = query.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SavedQueryName.derived(from: query.sql) : query.name
    }
}
