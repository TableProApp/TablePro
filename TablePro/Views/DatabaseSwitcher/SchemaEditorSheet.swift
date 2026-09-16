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
///
/// The content scrolls and the buttons do not. A fixed-height sheet with three stretching sections
/// left the fields clustered at the top and two dead zones underneath, which is what this shape
/// replaces: every section is as tall as its own content, the sheet asks for the height that adds
/// up to, and only the scroll view gives way when that exceeds the cap.
struct SchemaEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject var model: SchemaEditorViewModel
    var onCompleted: ((String) -> Void)?

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
        .frame(width: 540)
        .frame(minHeight: 320, maxHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            if !model.isApplying { dismiss() }
        }
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var title: String {
        switch model.mode {
        case .create:
            String(format: String(localized: "New %@"), entityName)
        case .edit(let name):
            String(format: String(localized: "Edit %1$@ \"%2$@\""), entityName, name)
        }
    }

    /// The database the change lands in, named before the user fills the form rather than after
    /// they press the button.
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
            Text(String(format: String(localized: "Could not load this %@"), entityName.lowercased()))
                .font(.body.weight(.medium))
            RevealedTextView(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Retry")) {
                Task { await model.load() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                generalSection

                if model.supportsPrivileges {
                    privilegesSection
                }

                statementsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        /// The whole form, not just the buttons: `apply()` executes the plan it built when the
        /// button was pressed, so a name typed while the statements were in flight would create one
        /// schema and report another.
        .disabled(model.isApplying)
    }

    // MARK: - General

    private var generalSection: some View {
        SchemaEditorSection(title: String(localized: "General")) {
            Form {
                TextField(
                    String(localized: "Name"),
                    text: $model.name,
                    prompt: Text(String(format: String(localized: "%@ name"), entityName.lowercased()))
                )
                .disabled(!model.isNameEditable)

                if model.supportsOwner {
                    ownerField
                }

                TextField(
                    String(localized: "Comment"),
                    text: $model.comment,
                    prompt: Text(String(localized: "Optional"))
                )
            }
            .formStyle(.columns)

            if let problem = model.nameProblem, !model.name.isEmpty {
                Label(problem.message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
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

    // MARK: - Privileges

    private var privilegesSection: some View {
        SchemaEditorSection(title: String(localized: "Privileges"), accessory: { addRoleMenu }) {
            if model.granteeRows.isEmpty {
                Text(emptyPrivilegesMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SchemaPrivilegeTable(model: model)
                    .frame(height: tableHeight)
            }
        }
    }

    /// A new schema has no grants, so the section carries the one control that does anything until
    /// a role is added. Opening on an empty table was a box the user had to look past.
    private var emptyPrivilegesMessage: String {
        model.privileges.isEmpty
            ? String(localized: "No privileges can be granted on a schema here.")
            : String(localized: "No roles have access yet. Add one to grant it.")
    }

    /// Sized to the rows it has rather than to the space left over, capped so a server with many
    /// roles scrolls inside the table instead of pushing the statements off the sheet.
    private var tableHeight: CGFloat {
        let heading: CGFloat = 26
        let row: CGFloat = 24
        return heading + min(CGFloat(model.granteeRows.count), 6) * row + 8
    }

    private var addRoleMenu: some View {
        Menu {
            ForEach(availableGrantees, id: \.self) { grantee in
                Button(grantee.displayName) { model.addGrantee(grantee) }
            }
        } label: {
            Label(String(localized: "Add Role"), systemImage: "plus")
        }
        .menuStyle(.button)
        .accessoryBarStyle()
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

    // MARK: - Statements

    private var statementsSection: some View {
        SchemaEditorSection(title: String(localized: "Statements")) {
            if model.plannedStatements.isEmpty {
                Text(emptyStatementsMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SQLStatementPreview(
                    prepared: SQLReviewSheet.build(
                        statements: model.plannedStatements,
                        databaseType: model.databaseType
                    ),
                    databaseType: model.databaseType
                )
                .frame(height: 132)
            }
        }
    }

    /// "No changes to apply" is edit-mode language. A create with nothing typed has not failed to
    /// change anything, it has not been told what to make yet.
    private var emptyStatementsMessage: String {
        switch model.mode {
        case .create:
            String(format: String(localized: "Name the %@ to see the statements."), entityName.lowercased())
        case .edit:
            String(localized: "No changes to apply.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let failure = model.failure {
                InlineErrorBanner(message: failure)
            }
            HStack(spacing: 12) {
                if let count = statementCount {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

    private var statementCount: String? {
        let count = model.plannedStatements.count
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 statement")
            : String(format: String(localized: "%lld statements"), Int64(count))
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

/// One titled group in the schema sheet.
///
/// A heading over its content rather than a `GroupBox`, because the sheet stacks three of these and
/// nested boxes inside a sheet inside a window reads as three levels of chrome for one form.
private struct SchemaEditorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
