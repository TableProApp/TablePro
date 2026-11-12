//
//  ObjectListingList.swift
//  TablePro
//

import Combine
import Foundation

/// The columns a reader showed or hid in the Objects list, per object kind. Device-local, never synced.
@MainActor
internal final class ObjectListingColumnVisibilityStore {
    internal static let shared = ObjectListingColumnVisibilityStore()

    private static let keyPrefix = "com.TablePro.objectsList.columns."

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    /// Column id to shown, only for the columns the reader changed. Every other column keeps its default.
    internal func choices(for kind: SidebarObjectKind) -> [String: Bool] {
        defaults.dictionary(forKey: Self.key(kind))?.compactMapValues { $0 as? Bool } ?? [:]
    }

    internal func setColumn(_ columnID: String, shown: Bool, kind: SidebarObjectKind) {
        var choices = choices(for: kind)
        choices[columnID] = shown
        defaults.set(choices, forKey: Self.key(kind))
    }

    private static func key(_ kind: SidebarObjectKind) -> String {
        keyPrefix + kind.persistenceName
    }
}

/// The rows, columns, sort and selection the Objects list shows for one tab.
///
/// It outlives the list's view, so a tab switch keeps the sort, the selection and the column widths.
/// The selection is held by object rather than by position, so a refresh that lists a new table above
/// the selected one keeps the same table selected.
@MainActor
internal final class ObjectListingList: ObservableObject {
    @Published private(set) var columns: [ObjectListingColumn] = []
    @Published private(set) var rows: [ObjectListingRow] = []
    @Published private(set) var sort: ObjectListingSort?
    @Published private(set) var selection: Set<ObjectListingItem.Key> = []
    @Published private(set) var columnChoices: [String: Bool]
    /// Moves whenever `rows` or `columns` is replaced, so the table reloads only then.
    @Published private(set) var revision = 0

    /// Widths the reader dragged a column to, kept for the next time the tab's view is made.
    var columnWidths: [String: CGFloat] = [:]

    /// The reader sorted the list, which keeps a preview tab.
    var onSortChange: (() -> Void)?

    let kind: SidebarObjectKind

    private let containerName: String?
    private let visibility: ObjectListingColumnVisibilityStore
    private let formatter: () -> ObjectListingValueFormatter
    private var allRows: [ObjectListingRow] = []
    private var filterText = ""

    init(
        kind: SidebarObjectKind,
        containerName: String?,
        visibility: ObjectListingColumnVisibilityStore = .shared,
        formatter: @escaping () -> ObjectListingValueFormatter = { ObjectListingValueFormatter() }
    ) {
        self.kind = kind
        self.containerName = containerName
        self.visibility = visibility
        self.formatter = formatter
        columnChoices = visibility.choices(for: kind)
    }

    /// The columns the list draws, in order.
    var shownColumns: [ObjectListingColumn] {
        columns.filter(isShown)
    }

    func isShown(_ column: ObjectListingColumn) -> Bool {
        columnChoices[column.id] ?? column.isShownByDefault
    }

    /// The selected objects in the order the list shows them.
    var selectedItems: [ObjectListingItem] {
        rows.filter { selection.contains($0.item.key) }.map(\.item)
    }

    /// A listing landed or the filter changed. Rows the filter hides leave the selection, so a
    /// command never acts on an object the reader cannot see.
    func show(_ listing: TableListing, filterText: String) {
        let columns = ObjectListingColumnLayout.columns(of: listing, containerName: containerName)
        allRows = ObjectListingRowBuilder.rows(of: listing, columns: columns, formatter: formatter())
        if columns != self.columns {
            self.columns = columns
        }
        self.filterText = filterText
        arrangeRows()
    }

    func applyFilter(_ text: String) {
        guard text != filterText else { return }
        filterText = text
        arrangeRows()
    }

    func setSort(_ sort: ObjectListingSort?) {
        guard sort != self.sort else { return }
        self.sort = sort
        arrangeRows()
        onSortChange?()
    }

    func select(_ keys: Set<ObjectListingItem.Key>) {
        guard keys != selection else { return }
        selection = keys
    }

    func setColumn(_ columnID: String, shown: Bool) {
        // Name is what every row is read by, so it never hides.
        guard columnID != "name", columns.contains(where: { $0.id == columnID }) else { return }
        columnChoices[columnID] = shown
        visibility.setColumn(columnID, shown: shown, kind: kind)
    }

    private func arrangeRows() {
        let filtered = allRows.filter { ObjectListingFilter.keeps($0.item.name, matching: filterText) }
        rows = ObjectListingRowBuilder.sorted(filtered, by: sort, columns: columns)
        let shownKeys = Set(rows.map(\.item.key))
        let kept = selection.intersection(shownKeys)
        if kept != selection {
            selection = kept
        }
        revision &+= 1
    }
}
