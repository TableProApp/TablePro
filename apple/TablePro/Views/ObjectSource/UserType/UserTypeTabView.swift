//
//  UserTypeTabView.swift
//  TablePro
//
//  A type's tab: its properties and members, edited by queuing changes that Save Changes applies,
//  and its definition as the server rebuilds it.
//

import SwiftUI
import TableProPluginKit
import TableProTheme

enum UserTypeEditorSection: String, Hashable, CaseIterable {
    case general
    case members
    case definition
}

/// The sheet a member edit opens. Each carries what it edits, so a queue that moves while the sheet
/// is up cannot redirect it.
enum UserTypeEditorSheet: Identifiable, Equatable {
    case addLabel
    case renameLabel(String)
    case addField
    case editField(name: String, type: String)
    case addCheck

    var id: String {
        switch self {
        case .addLabel: "addLabel"
        case .renameLabel(let label): "renameLabel:\(label)"
        case .addField: "addField"
        case .editField(let name, _): "editField:\(name)"
        case .addCheck: "addCheck"
        }
    }
}

struct UserTypeTabView: View {
    @ObservedObject var model: UserTypeEditorModel
    let databaseType: DatabaseType
    let isReadOnly: Bool
    let onOpenInEditor: (String) -> Void
    let onChangeStateChanged: (Bool) -> Void
    let onLeave: () -> Void
    let onPreviewSQL: () -> Void
    let onSave: () -> Void

    @State private var sheet: UserTypeEditorSheet?

    /// A read-only connection still shows a queue it already holds, so it can be discarded.
    private var showsEditor: Bool { model.support.isEditable && (!isReadOnly || model.hasChanges) }
    private var isDisabled: Bool { isReadOnly || model.isSaving || model.needsReload }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.loadIfNeeded() }
        .onAppear { onChangeStateChanged(model.hasChanges) }
        .onDisappear(perform: onLeave)
        .onChange(of: model.hasChanges) { onChangeStateChanged($0) }
        .sheet(item: $sheet) { sheet in
            UserTypeMemberSheet(sheet: sheet, model: model, databaseType: databaseType)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.objectRef.kindIconName)
                .foregroundStyle(Color.accentColor)
            Text(model.objectRef.displayIdentity)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.objectRef.kindDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
            Spacer()
            if model.isSaving {
                ProgressView().controlSize(.small)
                Text("Saving Changes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isReadOnly || !model.support.isEditable, model.loadState == .loaded {
                Text("Read Only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isSaving)
            .help(String(localized: "Reload from the database"))
            .accessibilityLabel(String(localized: "Reload"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .paneBarBackground()
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor))
        case .failed(let message):
            UnavailableStateView {
                Label("Source Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                RevealedTextView(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.load() }
                }
            }
            .themeBackground(.editorBackground, native: Color(nsColor: .textBackgroundColor))
        case .loaded:
            if showsEditor, let projection = model.projection {
                editor(projection)
            } else {
                definition
            }
        }
    }

    private var definition: some View {
        ObjectSourceView(
            source: model.serverType?.definition ?? "",
            databaseType: databaseType,
            exportFileName: model.objectRef.suggestedFileName,
            attributes: model.serverType?.attributes ?? [],
            onOpenInEditor: { onOpenInEditor(model.serverType?.definition ?? "") }
        )
    }

    private var reloadBar: some View {
        HStack(spacing: 12) {
            Label(
                String(localized: "The changes were saved, but the type could not be read back. Reload before editing it again."),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Reload")) {
                Task { await model.load() }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paneBarBackground(Color(nsColor: .controlBackgroundColor))
    }

    private var sections: [UserTypeEditorSection] {
        memberTitle == nil ? [.general, .definition] : [.general, .members, .definition]
    }

    private var memberTitle: String? {
        switch model.kind {
        case .enumeration: String(localized: "Labels")
        case .composite: String(localized: "Fields")
        case .domain: String(localized: "Constraints")
        default: nil
        }
    }

    private func title(for section: UserTypeEditorSection) -> String {
        switch section {
        case .general: String(localized: "General")
        case .members: memberTitle ?? ""
        case .definition: String(localized: "Definition")
        }
    }

    private func editor(_ projection: UserTypeDraft.Projection) -> some View {
        VStack(spacing: 0) {
            TabView(selection: $model.section) {
                ForEach(sections, id: \.self) { section in
                    pane(for: section, draft: projection.draft)
                        .tabItem { Text(title(for: section)) }
                        .tag(section)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("user-type-section-picker")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.needsReload {
                Divider()
                reloadBar
            }
            if model.hasChanges || model.saveSummary != nil {
                Divider()
                UserTypePendingChangesView(model: model, canSave: !isReadOnly, onPreviewSQL: onPreviewSQL, onSave: onSave)
            }
        }
        .onChange(of: model.kind) { _ in
            if !sections.contains(model.section) { model.section = .general }
        }
    }

    @ViewBuilder
    private func pane(for section: UserTypeEditorSection, draft: UserTypeDraft) -> some View {
        switch section {
        case .general:
            UserTypeGeneralPane(model: model, draft: draft, isDisabled: isDisabled)
        case .members:
            UserTypeMembersPane(model: model, draft: draft, isDisabled: isDisabled) { sheet = $0 }
        case .definition:
            definition
        }
    }
}
