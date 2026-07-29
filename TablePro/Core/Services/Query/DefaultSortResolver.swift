import Foundation
import TableProPluginKit

enum DefaultSortResolver {
    static func resolveSortState(
        behavior: DefaultSortBehavior,
        pluginHint: DefaultSortHint,
        primaryKeyColumns: [String],
        allColumns: [String]
    ) -> SortState {
        let names: [String]
        switch pluginHint {
        case .suppress:
            return SortState()
        case .forceColumns(let cols):
            names = cols
        case .useAppDefault:
            switch behavior {
            case .none:
                return SortState()
            case .primaryKey:
                names = primaryKeyColumns
            case .firstColumn:
                names = allColumns.first.map { [$0] } ?? []
            }
        }

        var columnsOut: [SortColumn] = []
        for name in names {
            guard let index = allColumns.firstIndex(of: name) else { continue }
            columnsOut.append(SortColumn(columnIndex: index, direction: .ascending))
        }
        guard !columnsOut.isEmpty else { return SortState() }
        return SortState(columns: columnsOut, source: .defaultSort)
    }
}
