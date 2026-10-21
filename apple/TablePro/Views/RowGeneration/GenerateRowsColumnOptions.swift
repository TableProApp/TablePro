//
//  GenerateRowsColumnOptions.swift
//  TablePro
//

import SwiftUI

internal struct GenerateRowsColumnOptions: View {
    @ObservedObject internal var session: RowGenerationSession
    internal let column: RowGenerationColumn

    private var settings: RowGeneratorSettings? {
        session.columnSettings(column.name)
    }

    internal var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Type"), value: column.typeName)
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(column.name)
            }
            Section {
                Picker(String(localized: "Generator"), selection: field(\.kind, fallback: .serverDefault)) {
                    ForEach(column.availableKinds, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .disabled(column.availableKinds.count < 2)
                .accessibilityIdentifier("generate-rows-generator")
                if let settings {
                    kindOptions(settings)
                    if column.isNullable, !column.isUnique, settings.kind != .serverDefault {
                        ratio(String(localized: "NULL"), \.nullRatio)
                    }
                }
            }
            let issues = session.issues(for: column.name)
            if !issues.isEmpty {
                Section {
                    ForEach(issues) { issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var facts: [String] {
        var facts: [String] = []
        switch column.ownership {
        case .computed:
            facts.append(String(localized: "The server computes this column, so it is left out."))
        case .assigned:
            facts.append(String(localized: "The server fills this column when it is left out."))
        case .none:
            break
        }
        if column.isUnique {
            facts.append(String(localized: "Values never repeat: the column is a key or unique."))
        }
        if let slot = column.reference, let source = session.table?.reference(id: slot.sourceId) {
            facts.append(String(
                format: String(localized: "References %1$@, which holds %2$@ values to pick from."),
                source.referencedTable,
                source.tuples.count.formatted(.number.grouping(.automatic))
            ))
        }
        if !column.isNullable {
            facts.append(String(localized: "Cannot be NULL."))
        }
        return facts
    }

    // swiftlint:disable:next cyclomatic_complexity
    @ViewBuilder
    private func kindOptions(_ settings: RowGeneratorSettings) -> some View {
        switch settings.kind {
        case .serverDefault:
            Text(String(localized: "Left out of the INSERT, so the server fills it or leaves it NULL."))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .reference:
            Text(String(localized: "Each row takes a value that exists in the referenced table."))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .sequence:
            number(String(localized: "Start"), \.integerMinimum)
            number(String(localized: "Step"), \.sequenceStep)
        case .integerRange:
            number(String(localized: "Minimum"), \.integerMinimum)
            number(String(localized: "Maximum"), \.integerMaximum)
        case .decimalRange:
            decimal(String(localized: "Minimum"), \.decimalMinimum)
            decimal(String(localized: "Maximum"), \.decimalMaximum)
            Stepper(value: field(\.decimalScale, fallback: 2), in: RowGenerationValidation.scaleRange) {
                LabeledContent(String(localized: "Decimal Places"), value: "\(settings.decimalScale)")
            }
        case .text:
            number(String(localized: "Shortest"), \.minLength)
            number(String(localized: "Longest"), \.maxLength)
        case .date, .dateTime:
            DatePicker(String(localized: "From"), selection: field(\.dateStart, fallback: Date()), displayedComponents: .date)
            DatePicker(String(localized: "To"), selection: field(\.dateEnd, fallback: Date()), displayedComponents: .date)
        case .uuid:
            Picker(String(localized: "Version"), selection: field(\.uuidVersion, fallback: .v4)) {
                Text(String(localized: "Version 4 (random)")).tag(UUIDVersion.v4)
                Text(String(localized: "Version 7 (ordered)")).tag(UUIDVersion.v7)
            }
        case .boolean:
            ratio(String(localized: "True"), \.trueRatio)
        case .list:
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Values, one per line"))
                TextEditor(text: listText)
                    .font(.body.monospaced())
                    .frame(height: 96)
                    .accessibilityIdentifier("generate-rows-values")
            }
        case .pattern:
            TextField(String(localized: "Pattern"), text: field(\.pattern, fallback: ""))
                .accessibilityIdentifier("generate-rows-pattern")
            Text(String(localized: "# is a digit, ? a letter, * a letter or digit, and \\ makes the next character literal."))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .firstName, .lastName, .fullName, .email, .phone, .streetAddress, .city, .country, .time, .json:
            EmptyView()
        }
    }

    private func number<Value: BinaryInteger>(
        _ title: String,
        _ keyPath: WritableKeyPath<RowGeneratorSettings, Value>
    ) -> some View {
        TextField(title, value: field(keyPath, fallback: 0), format: IntegerFormatStyle<Value>().grouping(.never))
    }

    private func decimal(_ title: String, _ keyPath: WritableKeyPath<RowGeneratorSettings, Double>) -> some View {
        TextField(title, value: field(keyPath, fallback: 0), format: .number.grouping(.never))
    }

    private func ratio(_ title: String, _ keyPath: WritableKeyPath<RowGeneratorSettings, Double>) -> some View {
        let value = field(keyPath, fallback: 0)
        return LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...1, step: 0.05)
                    .labelsHidden()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // Kept as typed, blank lines included, so the editor never loses the line being started; blanks are skipped
    // when values are drawn.
    private var listText: Binding<String> {
        Binding(
            get: { session.columnSettings(column.name)?.values.joined(separator: "\n") ?? "" },
            set: { text in session.updateColumn(column.name) { $0.values = text.components(separatedBy: "\n") } }
        )
    }

    private func field<Value>(_ keyPath: WritableKeyPath<RowGeneratorSettings, Value>, fallback: Value) -> Binding<Value> {
        let name = column.name
        return Binding(
            get: { session.columnSettings(name)?[keyPath: keyPath] ?? fallback },
            set: { value in session.updateColumn(name) { $0[keyPath: keyPath] = value } }
        )
    }
}
