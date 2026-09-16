//
//  SchemaEditorSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Create Schema and Edit Schema, which are the same form with a different set of fields enabled.
///
/// One sheet rather than two, and a sheet rather than a popover, because the task is scoped, short
/// and committal, which is what the HIG puts in a sheet. The generated statements sit inside it
/// rather than behind a second sheet: only one sheet shows at a time, and a preview the user has
/// to open another window to read is a preview nobody checks.
struct SchemaEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var model: SchemaEditorViewModel
    var onCompleted: ((String) -> Void)?

    @State private var newGrantee = ""

    private var entityName: String {
        PluginManager.shared.schemaEntityName(for: model.databaseType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: 520, height: model.supportsPrivileges ? 620 : 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            if !model.isApplying { dismiss() }
        }
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: String {
        switch model.mode {
        case .create:
            String(format: String(localized: "New %@"), entityName)
        case .edit(let name):
            String(format: String(localized: "Edit %1$@ \"%2$@\""), entityName, name)
        }
    }

    /// The fully qualified target and the database it lands in, named before the user fills the
    /// form rather than after they press the button.
    private var subtitle: String? {
        guard let database = model.database, !database.isEmpty else { return nil }
        return String(format: String(localized: "In database %@"), database)
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            loadingState
        case .failed(let message):
            failureState(message)
        case .ready:
            form
        }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Loading…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(String(localized: "Could not load this schema"))
                .font(.body.weight(.medium))
            RevealedTextView(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "Retry")) {
                Task { await model.load() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            generalSection

            if model.supportsPrivileges {
                Divider()
                privilegesSection
            }

            Divider()
            previewSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        /// The whole form, not just the buttons: `apply()` executes the plan it built when the
        /// button was pressed, so a name typed while the statements were in flight would create one
        /// schema and report another.
        .disabled(model.isApplying)
    }

    private var generalSection: some View {
        Form {
            TextField(
                String(localized: "Name"),
                text: $model.name,
                prompt: Text(String(format: String(localized: "%@ name"), entityName))
            )
            .disabled(!model.isNameEditable)

            if model.supportsOwner {
                ownerField
            }

            TextField(String(localized: "Comment"), text: $model.comment, prompt: Text(""))
        }
        .formStyle(.columns)
        .overlay(alignment: .bottomLeading) {
            if let problem = model.nameProblem, !model.name.isEmpty {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .offset(y: 14)
            }
        }
    }

    /// A menu picker over the roles the server has, and a plain field when that list is not
    /// available. Redshift and CockroachDB both change a schema's owner but expose no role list
    /// here, and a read-only label would leave the capability advertised and unusable.
    ///
    /// **Database default** is a create-time choice only. On an existing schema there is no such
    /// thing: clearing the field means "leave the owner alone", so offering it as a selection gave
    /// the user a pick that silently did nothing.
    @ViewBuilder
    private var ownerField: some View {
        if model.ownerCandidates.isEmpty {
            TextField(
                String(localized: "Owner"),
                text: $model.owner,
                prompt: Text(String(localized: "Database default"))
            )
        } else {
            Picker(String(localized: "Owner"), selection: $model.owner) {
                if case .create = model.mode {
                    Text(String(localized: "Database default")).tag("")
                    Divider()
                } else if !model.ownerCandidates.contains(model.owner) {
                    Text(model.owner.isEmpty ? String(localized: "Unknown") : model.owner)
                        .tag(model.owner)
                    Divider()
                }
                ForEach(model.ownerCandidates, id: \.self) { role in
                    Text(role).tag(role)
                }
            }
        }
    }

    private var privilegesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Privileges"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                addGranteeControl
            }
            SchemaPrivilegeTable(model: model)
                .frame(minHeight: 140)
        }
    }

    private var addGranteeControl: some View {
        Menu {
            ForEach(availableGrantees, id: \.self) { grantee in
                Button(grantee.displayName) { model.addGrantee(grantee) }
            }
        } label: {
            Label(String(localized: "Add Role"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(availableGrantees.isEmpty)
    }

    /// The all-users group is offered alongside the real roles because a schema ACL can name it
    /// and users reach for it constantly: it is how you open a schema to everyone. It is a
    /// separate case rather than a role called PUBLIC, because a real role can be named that.
    private var availableGrantees: [PluginSchemaGrantee] {
        let present = Set(model.granteeRows.map(\.grantee))
        let candidates: [PluginSchemaGrantee] = [.publicGroup] + model.ownerCandidates.map { .role($0) }
        return candidates.filter { !present.contains($0) }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Statements"))
                .font(.subheadline.weight(.medium))
            if model.plannedStatements.isEmpty {
                Text(String(localized: "No changes to apply."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            } else {
                SQLStatementPreview(
                    prepared: SQLReviewSheet.build(
                        statements: model.plannedStatements,
                        databaseType: model.databaseType
                    ),
                    databaseType: model.databaseType
                )
                .frame(minHeight: 100)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let failure = model.failure {
                InlineErrorBanner(message: failure)
            }
            HStack {
                Spacer()
                if model.isApplying {
                    ProgressView().controlSize(.small)
                }
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isApplying)
                Button(primaryTitle) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var primaryTitle: String {
        switch model.mode {
        case .create: String(localized: "Create")
        case .edit: String(localized: "Save")
        }
    }

    private func submit() {
        Task {
            let outcome = await model.apply()
            /// Reported on a partial failure too: on an engine with no transactional DDL the rename
            /// can land while a later statement fails, and a tab left on the old name is pointing
            /// at a schema the server no longer has.
            if outcome.succeeded || outcome.renameCommitted {
                onCompleted?(outcome.committedName)
            }
            guard outcome.succeeded else { return }
            dismiss()
        }
    }
}
