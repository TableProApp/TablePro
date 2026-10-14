@testable import TablePro

@MainActor
final class InMemoryColumnLayoutStore: ColumnLayoutPersisting {
    var layouts: [ColumnLayoutTableKey: ColumnLayoutState] = [:]
    var hidden: [ColumnLayoutTableKey: Set<String>] = [:]

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { layouts[key] }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) { layouts[key] = layout }
    func clear(for key: ColumnLayoutTableKey) { layouts[key] = nil }
    func loadHiddenColumns(for key: ColumnLayoutTableKey) -> Set<String> { hidden[key] ?? [] }
    func saveHiddenColumns(_ hidden: Set<String>, for key: ColumnLayoutTableKey) { self.hidden[key] = hidden }
}
