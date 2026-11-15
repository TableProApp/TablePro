import SwiftUI

// Rows are picked by their place on the loaded page, so anything that replaces the page clears the pick.
nonisolated struct RowSelection: Equatable, Sendable {
    private(set) var isActive = false
    private(set) var rows: Set<Int> = []

    var count: Int { rows.count }

    var editMode: EditMode { isActive ? .active : .inactive }

    mutating func begin() {
        isActive = true
        rows = []
    }

    mutating func end() {
        isActive = false
        rows = []
    }

    mutating func toggle(_ index: Int) {
        guard isActive else { return }
        if rows.contains(index) {
            rows.remove(index)
        } else {
            rows.insert(index)
        }
    }

    mutating func replace(with indices: Set<Int>) {
        guard isActive else { return }
        rows = indices
    }

    mutating func selectAll(count: Int) {
        guard isActive else { return }
        rows = Set(0..<max(0, count))
    }

    mutating func clearRows() {
        rows = []
    }

    func contains(_ index: Int) -> Bool {
        rows.contains(index)
    }

    func selectsAll(of count: Int) -> Bool {
        count > 0 && (0..<count).allSatisfy(rows.contains)
    }

    // In page order, and only rows the page still holds: a memory trim drops rows from the head.
    func indices(within count: Int) -> [Int] {
        rows.filter { $0 >= 0 && $0 < count }.sorted()
    }
}

// The cards layout is a `List`: edit mode draws the circles, and its selection binding picks the rows.
enum RowSelectionBinding {
    static func rows(_ selection: Binding<RowSelection>) -> Binding<Set<Int>>? {
        guard selection.wrappedValue.isActive else { return nil }
        return Binding(
            get: { selection.wrappedValue.rows },
            set: { selection.wrappedValue.replace(with: $0) }
        )
    }

    static func editMode(_ selection: Binding<RowSelection>) -> Binding<EditMode> {
        Binding(
            get: { selection.wrappedValue.editMode },
            set: { mode in
                if mode == .inactive {
                    selection.wrappedValue.end()
                } else if !selection.wrappedValue.isActive {
                    selection.wrappedValue.begin()
                }
            }
        )
    }
}

// Select All, the count and Done, for a results pane that has no navigation bar of its own.
struct RowSelectionHeader: View {
    @Binding var selection: RowSelection
    let rowCount: Int

    var body: some View {
        let selectsAll = selection.selectsAll(of: rowCount)
        HStack(spacing: 12) {
            Button(selectsAll ? String(localized: "Deselect All") : String(localized: "Select All")) {
                if selectsAll {
                    selection.clearRows()
                } else {
                    selection.selectAll(count: rowCount)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            Text("^[\(selection.count) Row](inflect: true) Selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                selection.end()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
