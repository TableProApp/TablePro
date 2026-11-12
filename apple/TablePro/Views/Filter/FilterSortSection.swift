//
//  FilterSortSection.swift
//  TablePro
//

import SwiftUI

/// The filter panel's Sort By section. It edits `TabFilterState.sortDraft`, seeded from the tab's
/// sort, and Apply Filter & Sort runs it with the filters.
struct FilterSortSection: View {
    @Binding var state: TabFilterState
    let columns: [String]
    let appliedSort: [FilterSortCriterion]
    let newSortDirection: SortDirection

    private let rowButtonGlyphSize: CGFloat = 14

    /// Matches the filter rows' column picker, so a long column name truncates instead of widening the panel.
    private static let columnPickerMaximumWidth: CGFloat = 160

    private var criteria: [FilterSortCriterion] {
        state.sortCriteria(applied: appliedSort)
    }

    private var canAddCriterion: Bool {
        let used = Set(criteria.map(\.columnName))
        return columns.contains { !used.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Sort By")
                    .font(.callout.weight(.medium))

                Spacer()

                Button(action: addCriterion) {
                    Image(systemName: "plus")
                        .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canAddCriterion)
                .accessibilityLabel(String(localized: "Add sort criterion"))
                .help(String(localized: "Add sort criterion"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if criteria.isEmpty {
                Text("Click + to add sort criteria")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(criteria) { criterion in
                        criterionRow(criterion)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Sort By"))
    }

    private func criterionRow(_ criterion: FilterSortCriterion) -> some View {
        HStack(spacing: 4) {
            Picker(String(localized: "Sort column"), selection: columnBinding(for: criterion)) {
                ForEach(columnChoices(for: criterion), id: \.self) { column in
                    Text(column).tag(column)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: Self.columnPickerMaximumWidth)
            .labelsHidden()
            .help(String(localized: "Select sort column"))

            Picker(String(localized: "Sort direction"), selection: directionBinding(for: criterion)) {
                ForEach(SortDirection.allCases) { direction in
                    Text(direction.displayName).tag(direction)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .labelsHidden()

            Spacer(minLength: 0)

            Button {
                removeCriterion(criterion)
            } label: {
                Image(systemName: "minus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Remove sort criterion"))
            .help(String(localized: "Remove sort criterion"))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }

    /// Columns no other key sorts by, plus this key's own column even once the result lost it, so the
    /// picker never shows a blank selection.
    private func columnChoices(for criterion: FilterSortCriterion) -> [String] {
        let usedElsewhere = Set(criteria.map(\.columnName)).subtracting([criterion.columnName])
        var choices = columns.filter { !usedElsewhere.contains($0) }
        if !columns.contains(criterion.columnName) {
            choices.insert(criterion.columnName, at: 0)
        }
        return choices
    }

    private func columnBinding(for criterion: FilterSortCriterion) -> Binding<String> {
        Binding(
            get: { criterion.columnName },
            set: { newColumn in
                replaceCriterion(criterion.columnName) { $0.columnName = newColumn }
            }
        )
    }

    private func directionBinding(for criterion: FilterSortCriterion) -> Binding<SortDirection> {
        Binding(
            get: { criterion.direction },
            set: { newDirection in
                replaceCriterion(criterion.columnName) { $0.direction = newDirection }
            }
        )
    }

    /// One whole-value write, reading the key as it is now rather than as the row last drew it.
    private func replaceCriterion(_ columnName: String, _ change: (inout FilterSortCriterion) -> Void) {
        var next = state
        guard var replacement = next.sortCriteria(applied: appliedSort).first(where: { $0.columnName == columnName })
        else { return }
        change(&replacement)
        next.updateSortCriterion(columnName, to: replacement, applied: appliedSort)
        state = next
    }

    private func addCriterion() {
        var next = state
        next.addSortCriterion(applied: appliedSort, columns: columns, direction: newSortDirection)
        state = next
    }

    private func removeCriterion(_ criterion: FilterSortCriterion) {
        var next = state
        next.removeSortCriterion(criterion.columnName, applied: appliedSort)
        state = next
    }
}
