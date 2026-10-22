//
//  CreateUserTypeSheet.swift
//  TablePro
//

import os
import SwiftUI
import TableProPluginKit

/// Creates an enum, a composite or a domain in the schema the Types section belongs to. The
/// statement it will run is shown before Create, and the execution gate confirms it as usual.
struct CreateUserTypeSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CreateUserTypeSheet")
    private static let kindOrder: [UserDefinedTypeInfo.Kind] = [.enumeration, .composite, .domain]

    @Environment(\.dismiss) private var dismiss

    let connection: DatabaseConnection
    let database: String
    let schema: String?
    let onCreated: (PluginUserDefinedTypeDefinition) -> Void

    @State private var draft: UserTypeCreationDraft
    @State private var isCreating = false
    @State private var failure: String?

    init(
        connection: DatabaseConnection,
        database: String,
        schema: String?,
        onCreated: @escaping (PluginUserDefinedTypeDefinition) -> Void
    ) {
        self.connection = connection
        self.database = database
        self.schema = schema
        self.onCreated = onCreated
        let kinds = Self.creatableKinds(for: connection.id)
        _draft = State(initialValue: UserTypeCreationDraft(kind: kinds.first ?? .enumeration, schema: schema))
    }

    private static func creatableKinds(for connectionId: UUID) -> [UserDefinedTypeInfo.Kind] {
        let support = DatabaseObjectToolEligibility.Support.of(DatabaseManager.shared.driver(for: connectionId))
        return kindOrder.filter { support.creatableTypeKinds.contains($0) }
    }

    private var kinds: [UserDefinedTypeInfo.Kind] { Self.creatableKinds(for: connection.id) }

    /// Shown once the draft is complete, so the sheet never shows a statement the server would refuse.
    private var statements: [String] {
        guard draft.problems.isEmpty,
              let definition = draft.definition,
              let driver = DatabaseManager.shared.driver(for: connection.id)
        else { return [] }
        return driver.createUserDefinedTypeStatements(definition) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Type")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section {
                    Picker(String(localized: "Kind"), selection: $draft.kind) {
                        ForEach(kinds, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("new-type-kind")
                    TextField(String(localized: "Name"), text: $draft.name)
                        .accessibilityIdentifier("new-type-name")
                    if let schema, !schema.isEmpty {
                        LabeledContent(String(localized: "Schema")) { Text(schema) }
                    }
                }
                members
                Section {
                    TextField(
                        String(localized: "Comment"),
                        text: $draft.comment,
                        prompt: Text("None"),
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                }
                if !statements.isEmpty {
                    Section(String(localized: "Statement")) {
                        Text(verbatim: statements.joined(separator: ";\n\n") + ";")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            Divider()
            DialogFooter {
                if let message = failure ?? draft.problems.first {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            } actions: {
                if isCreating { ProgressView().controlSize(.small) }
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Create")) {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || !draft.problems.isEmpty || statements.isEmpty)
                .accessibilityIdentifier("new-type-create")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
        .onChange(of: draft) { _ in failure = nil }
    }

    @ViewBuilder
    private var members: some View {
        switch draft.kind {
        case .enumeration:
            Section(String(localized: "Labels")) {
                ForEach(draft.labels) { label in
                    rowWithRemove(remove: { draft.labels.removeAll { $0.id == label.id } }) {
                        TextField(String(localized: "Label"), text: binding(\.labels, label.id, \.name))
                            .labelsHidden()
                    }
                }
                addButton(String(localized: "Add Label")) { draft.labels.append(.init()) }
            }
        case .composite:
            Section(String(localized: "Fields")) {
                ForEach(draft.fields) { field in
                    rowWithRemove(remove: { draft.fields.removeAll { $0.id == field.id } }) {
                        TextField(String(localized: "Name"), text: binding(\.fields, field.id, \.name), prompt: Text("Name"))
                            .labelsHidden()
                        SuggestionComboBox(
                            suggestions: { typeSuggestions },
                            placeholder: String(localized: "Type"),
                            accessibilityLabel: String(localized: "Type"),
                            value: binding(\.fields, field.id, \.type)
                        )
                    }
                }
                addButton(String(localized: "Add Field")) { draft.fields.append(.init()) }
            }
        case .domain:
            Section(String(localized: "Domain")) {
                LabeledContent(String(localized: "Base Type")) {
                    SuggestionComboBox(
                        suggestions: { typeSuggestions },
                        placeholder: "integer",
                        accessibilityLabel: String(localized: "Base Type"),
                        accessibilityIdentifier: "new-type-base-type",
                        value: $draft.baseType
                    )
                }
                TextField(String(localized: "Default"), text: $draft.defaultValue, prompt: Text("None"))
                Toggle(String(localized: "Not Null"), isOn: $draft.isNotNull)
            }
            Section(String(localized: "Checks")) {
                ForEach(draft.checks) { check in
                    rowWithRemove(remove: { draft.checks.removeAll { $0.id == check.id } }) {
                        TextField(String(localized: "Name"), text: binding(\.checks, check.id, \.name), prompt: Text("Name"))
                            .labelsHidden()
                            .frame(width: 120)
                        TextField(
                            String(localized: "Expression"),
                            text: binding(\.checks, check.id, \.expression),
                            prompt: Text(verbatim: "VALUE > 0")
                        )
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    }
                }
                addButton(String(localized: "Add Check")) { draft.checks.append(.init()) }
            }
        default:
            EmptyView()
        }
    }

    /// Looked up by id on every read and write: a row removed while its field still holds focus
    /// must not write into whichever row took its index.
    private func binding<Row: Identifiable>(
        _ rows: WritableKeyPath<UserTypeCreationDraft, [Row]>,
        _ id: Row.ID,
        _ member: WritableKeyPath<Row, String>
    ) -> Binding<String> {
        Binding(
            get: { draft[keyPath: rows].first { $0.id == id }?[keyPath: member] ?? "" },
            set: { value in
                guard let index = draft[keyPath: rows].firstIndex(where: { $0.id == id }) else { return }
                draft[keyPath: rows][index][keyPath: member] = value
            }
        )
    }

    private func rowWithRemove<Content: View>(
        remove: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove"))
            .accessibilityLabel(String(localized: "Remove"))
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }

    private var typeSuggestions: [String] {
        PluginManager.shared.columnTypesByCategory(for: connection.type).values.flatMap { $0 }.sorted()
    }

    private func create() async {
        guard let definition = draft.definition else { return }
        isCreating = true
        failure = nil
        defer { isCreating = false }
        let scope = DatabaseScope(connectionId: connection.id, database: database, schema: schema)
        do {
            try await UserTypeCreation.create(definition, in: scope, connection: connection)
            dismiss()
            onCreated(definition)
        } catch ExecutionGateError.cancelledByUser {
            return
        } catch {
            Self.logger.error("Create Type failed: \(error.publicLogShape, privacy: .public)")
            failure = error.localizedDescription
        }
    }
}
