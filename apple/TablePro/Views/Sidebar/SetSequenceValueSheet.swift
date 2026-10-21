//
//  SetSequenceValueSheet.swift
//  TablePro
//

import os
import SwiftUI
import TableProPluginKit

struct SetSequenceValueSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SetSequenceValueSheet")

    private enum Phase: Equatable {
        case loading
        case editing(PluginSequenceDetails)
        case saving(PluginSequenceDetails)
        case loadFailed(String)
    }

    private enum Source: Hashable {
        case ownedColumn
        case value
    }

    @Environment(\.dismiss) private var dismiss

    let target: DatabaseObjectTarget
    let connection: DatabaseConnection

    @State private var phase: Phase = .loading
    @State private var source: Source = .value
    @State private var valueText = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SequenceSheetHeader(title: String(localized: "Set Next Value"), subject: target.qualifiedName)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttonBar
        }
        .frame(width: 480, height: 440)
        .task { await load() }
    }

    private var details: PluginSequenceDetails? {
        switch phase {
        case .editing(let details), .saving(let details): details
        case .loading, .loadFailed: nil
        }
    }

    private var nextValue: PluginSequenceNextValue? {
        switch source {
        case .ownedColumn: return .afterOwnedColumn
        case .value: return SequenceSettingsDraft.number(valueText).map { .value($0) }
        }
    }

    private var statement: String? {
        guard let details, let nextValue,
              let driver = DatabaseManager.shared.driver(for: connection.id)
        else { return nil }
        return driver.sequenceNextValueStatement(for: details, nextValue: nextValue)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let message):
            UnavailableStateView {
                Label("Sequence Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await load() }
                }
            }
        case .editing(let details), .saving(let details):
            form(details)
        }
    }

    private func form(_ details: PluginSequenceDetails) -> some View {
        Form {
            Section {
                LabeledContent(String(localized: "Currently")) {
                    Text(details.nextValue.map { String($0) } ?? String(localized: "Unknown"))
                        .textSelection(.enabled)
                }
                if let owner = SequenceSheetHeader.owner(of: details) {
                    LabeledContent(String(localized: "Owned by"), value: owner)
                }
            }
            Section {
                if let owner = SequenceSheetHeader.owner(of: details) {
                    Picker(String(localized: "Next value"), selection: $source) {
                        Text(String(format: String(localized: "After the values already in %@"), owner))
                            .tag(Source.ownedColumn)
                        Text("Value").tag(Source.value)
                    }
                    .pickerStyle(.radioGroup)
                }
                TextField(String(localized: "Value"), text: $valueText)
                    .disabled(source != .value)
                    .accessibilityIdentifier("sequence-next-value")
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Section(String(localized: "SQL Preview")) {
                HighlightedSQLTextView(
                    sql: statement ?? "",
                    databaseType: connection.type,
                    lineLayout: .fitted(maxLines: 4)
                )
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
    }

    private var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    private var buttonBar: some View {
        HStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Set Value")) {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || statement == nil)
            .accessibilityIdentifier("sequence-next-value-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() async {
        phase = .loading
        do {
            let details = try await SequenceEditing.details(of: target)
            source = details.ownedByColumn == nil ? .value : .ownedColumn
            valueText = details.nextValue.map { String($0) } ?? ""
            phase = .editing(details)
        } catch {
            Self.logger.error("Failed to read sequence: \(error.publicLogShape, privacy: .public)")
            phase = .loadFailed(error.localizedDescription)
        }
    }

    private func save() async {
        guard let details, let nextValue else { return }
        phase = .saving(details)
        saveError = nil
        do {
            try await SequenceEditing.setNextValue(nextValue, of: details, target: target, connection: connection)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            phase = .editing(details)
        }
    }
}

struct SequenceSheetHeader: View {
    let title: String
    let subject: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subject)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    static func owner(of details: PluginSequenceDetails) -> String? {
        guard let table = details.ownedByTable, let column = details.ownedByColumn else { return nil }
        return "\(table).\(column)"
    }
}
