//
//  EditSequenceSheet.swift
//  TablePro
//

import os
import SwiftUI
import TableProPluginKit

struct EditSequenceSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EditSequenceSheet")

    private enum Phase: Equatable {
        case loading
        case editing(PluginSequenceDetails)
        case saving(PluginSequenceDetails)
        case loadFailed(String)
    }

    @Environment(\.dismiss) private var dismiss

    let target: DatabaseObjectTarget
    let connection: DatabaseConnection

    @State private var phase: Phase = .loading
    @State private var draft: SequenceSettingsDraft?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SequenceSheetHeader(title: String(localized: "Edit Sequence"), subject: target.qualifiedName)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttonBar
        }
        .frame(width: 480, height: 560)
        .task { await load() }
    }

    private var details: PluginSequenceDetails? {
        switch phase {
        case .editing(let details), .saving(let details): details
        case .loading, .loadFailed: nil
        }
    }

    private var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    private var statement: String? {
        guard let details, case .success(let settings) = draft?.settings,
              let driver = DatabaseManager.shared.driver(for: connection.id)
        else { return nil }
        return driver.alterSequenceStatement(for: details, settings: settings)
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
                if let dataType = details.dataType {
                    LabeledContent(String(localized: "Data type"), value: dataType)
                }
                if let start = details.startValue {
                    LabeledContent(String(localized: "Start"), value: String(start))
                }
                LabeledContent(
                    String(localized: "Next value"),
                    value: details.nextValue.map { String($0) } ?? String(localized: "Unknown")
                )
                if let owner = SequenceSheetHeader.owner(of: details) {
                    LabeledContent(String(localized: "Owned by"), value: owner)
                }
            }
            if draft != nil {
                Section {
                    TextField(String(localized: "Increment"), text: field(\.increment))
                    TextField(String(localized: "Minimum"), text: field(\.minValue))
                    TextField(String(localized: "Maximum"), text: field(\.maxValue))
                    TextField(String(localized: "Cache"), text: field(\.cacheSize))
                    Toggle(String(localized: "Cycle"), isOn: cycles)
                    if let message = problem ?? saveError {
                        Text(message)
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
            } else {
                Section {
                    Text("This sequence's settings could not be read, so they cannot be changed here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
    }

    private var problem: String? {
        guard case .failure(let problem) = draft?.settings else { return nil }
        return problem.message
    }

    private func field(_ keyPath: WritableKeyPath<SequenceSettingsDraft, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private var cycles: Binding<Bool> {
        Binding(
            get: { draft?.cycles ?? false },
            set: { draft?.cycles = $0 }
        )
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
            Button(String(localized: "Save")) {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || statement == nil)
            .accessibilityIdentifier("edit-sequence-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() async {
        phase = .loading
        do {
            let details = try await SequenceEditing.details(of: target)
            draft = details.settings.map(SequenceSettingsDraft.init)
            phase = .editing(details)
        } catch {
            Self.logger.error("Failed to read sequence: \(error.publicLogShape, privacy: .public)")
            phase = .loadFailed(error.localizedDescription)
        }
    }

    private func save() async {
        guard let details, case .success(let settings) = draft?.settings else { return }
        phase = .saving(details)
        saveError = nil
        do {
            try await SequenceEditing.alter(details, to: settings, target: target, connection: connection)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            phase = .editing(details)
        }
    }
}
