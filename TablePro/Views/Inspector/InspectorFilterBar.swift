//
//  InspectorFilterBar.swift
//  TablePro
//

import SwiftUI

enum CSVFilterOperator: String, CaseIterable, Identifiable {
    case contains
    case equals
    case notEquals
    case startsWith
    case endsWith
    case isEmpty
    case isNotEmpty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contains: return String(localized: "contains")
        case .equals: return String(localized: "equals")
        case .notEquals: return String(localized: "does not equal")
        case .startsWith: return String(localized: "starts with")
        case .endsWith: return String(localized: "ends with")
        case .isEmpty: return String(localized: "is empty")
        case .isNotEmpty: return String(localized: "is not empty")
        }
    }

    var needsValue: Bool {
        self != .isEmpty && self != .isNotEmpty
    }

    func matches(_ cell: String, value: String) -> Bool {
        switch self {
        case .contains: return cell.localizedCaseInsensitiveContains(value)
        case .equals: return cell.compare(value, options: .caseInsensitive) == .orderedSame
        case .notEquals: return cell.compare(value, options: .caseInsensitive) != .orderedSame
        case .startsWith: return cell.lowercased().hasPrefix(value.lowercased())
        case .endsWith: return cell.lowercased().hasSuffix(value.lowercased())
        case .isEmpty: return cell.isEmpty
        case .isNotEmpty: return !cell.isEmpty
        }
    }
}

struct FilterClause: Sendable, Identifiable {
    let id: UUID
    var column: Int
    var op: CSVFilterOperator
    var value: String

    static func empty(column: Int = 0) -> FilterClause {
        FilterClause(id: UUID(), column: column, op: .contains, value: "")
    }
}

extension FilterClause: Equatable {
    static func == (lhs: FilterClause, rhs: FilterClause) -> Bool {
        lhs.column == rhs.column && lhs.op == rhs.op && lhs.value == rhs.value
    }
}

struct InspectorFilterBar: View {
    @Bindable var state: InspectorViewState
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.filters) { clause in
                clauseRow(for: clause)
            }
            HStack {
                Button {
                    state.filters.append(FilterClause.empty())
                } label: {
                    Label(String(localized: "Add filter"), systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if state.filters.contains(where: { !$0.value.isEmpty || !$0.op.needsValue }) {
                    Button {
                        state.filters = [FilterClause.empty()]
                        onChange()
                    } label: {
                        Text(String(localized: "Clear all"))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func clauseRow(for clause: FilterClause) -> some View {
        let binding = clauseBinding(for: clause)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(state.filters.first?.id == clause.id ? 1 : 0)

            Picker("", selection: binding.column) {
                ForEach(Array(state.columnNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .onChange(of: clause.column) { _, _ in onChange() }

            Picker("", selection: binding.op) {
                ForEach(CSVFilterOperator.allCases) { op in
                    Text(op.label).tag(op)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            .onChange(of: clause.op) { _, _ in onChange() }

            if clause.op.needsValue {
                TextField(String(localized: "Filter value"), text: binding.value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onChange(of: clause.value) { _, _ in onChange() }
            } else {
                Color.clear.frame(maxWidth: 260)
            }

            Spacer()

            Button {
                state.filters.removeAll { $0.id == clause.id }
                onChange()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove filter"))
        }
    }

    private func clauseBinding(for clause: FilterClause) -> Binding<FilterClause> {
        Binding(
            get: { state.filters.first(where: { $0.id == clause.id }) ?? clause },
            set: { newValue in
                guard let index = state.filters.firstIndex(where: { $0.id == clause.id }) else { return }
                state.filters[index] = newValue
            }
        )
    }
}
