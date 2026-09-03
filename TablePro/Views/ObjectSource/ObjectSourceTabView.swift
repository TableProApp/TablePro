//
//  ObjectSourceTabView.swift
//  TablePro
//
//  Tab showing the source of one stored procedure, function, trigger or user-defined type.
//

import SwiftUI
import TableProPluginKit

@MainActor
@Observable
final class ObjectSourceLoader {
    enum State {
        case loading
        case loaded(source: String, attributes: [ObjectAttribute], enumLabels: [String])
        case failed(String)
    }

    private struct Fetched: Sendable {
        let source: String
        let attributes: [ObjectAttribute]
        let enumLabels: [String]
        let userType: UserDefinedTypeInfo?
    }

    private(set) var state: State = .loading

    /// The type as the server last described it, so an edit addresses the object on screen rather
    /// than whatever the sidebar listed when the tab was opened.
    private(set) var userType: UserDefinedTypeInfo?

    private let connectionId: UUID
    private let objectRef: DatabaseObjectRef

    init(connectionId: UUID, objectRef: DatabaseObjectRef) {
        self.connectionId = connectionId
        self.objectRef = objectRef
    }

    var source: String {
        if case .loaded(let source, _, _) = state { return source }
        return ""
    }

    var attributes: [ObjectAttribute] {
        if case .loaded(_, let attributes, _) = state { return attributes }
        return []
    }

    var enumLabels: [String] {
        if case .loaded(_, _, let labels) = state { return labels }
        return []
    }

    /// A refresh fetches before it commits, so a failed reload leaves the definition the reader is
    /// looking at on screen rather than replacing it with an error.
    func load(isRefresh: Bool = false) async {
        if !isRefresh { state = .loading }
        do {
            let fetched = try await fetch()
            userType = fetched.userType
            state = .loaded(source: fetched.source, attributes: fetched.attributes, enumLabels: fetched.enumLabels)
        } catch is CancellationError {
        } catch {
            guard case .loaded = state, isRefresh else {
                state = .failed(error.localizedDescription)
                return
            }
        }
    }

    /// One round trip. Re-listing the schema to recover the attributes cost a full catalog scan
    /// per open and per reload, for values the sidebar's listing already carried into the ref. A
    /// type is the exception: its labels are what the viewer edits, so they are read fresh.
    private func fetch() async throws -> Fetched {
        let scope = DatabaseScope(
            connectionId: connectionId,
            database: objectRef.database,
            schema: objectRef.schema
        )
        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { [objectRef] driver in
            switch objectRef.kind {
            case .procedure, .function:
                guard let routine = objectRef.routine else {
                    throw PluginObjectSourceError.unsupported(objectRef.name)
                }
                let source = try await driver.fetchRoutineDDL(routine)
                return Fetched(source: source, attributes: objectRef.attributes, enumLabels: [], userType: nil)
            case .trigger:
                guard let trigger = objectRef.trigger else {
                    throw PluginObjectSourceError.unsupported(objectRef.name)
                }
                let source = try await driver.fetchTriggerDDL(trigger)
                return Fetched(source: source, attributes: objectRef.attributes, enumLabels: [], userType: nil)
            case .userType:
                guard let type = objectRef.userType else {
                    throw PluginObjectSourceError.unsupported(objectRef.name)
                }
                let fetched = try await driver.fetchUserDefinedType(type)
                guard let source = fetched.definition, !source.isEmpty else {
                    throw PluginObjectSourceError.unsupported(objectRef.name)
                }
                return Fetched(
                    source: source,
                    attributes: fetched.attributes,
                    enumLabels: fetched.enumLabels,
                    userType: fetched
                )
            }
        }
    }
}

struct ObjectSourceTabView: View {
    let connectionId: UUID
    let databaseType: DatabaseType
    let objectRef: DatabaseObjectRef
    let onOpenInEditor: (String) -> Void

    @State private var loader: ObjectSourceLoader

    init(
        connectionId: UUID,
        databaseType: DatabaseType,
        objectRef: DatabaseObjectRef,
        onOpenInEditor: @escaping (String) -> Void
    ) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.objectRef = objectRef
        self.onOpenInEditor = onOpenInEditor
        _loader = State(wrappedValue: ObjectSourceLoader(connectionId: connectionId, objectRef: objectRef))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await loader.load() }
    }

    /// Only an enum has anything to edit in place: a label is appended or renamed with one
    /// statement. Every other object stays read-only here and is edited in a query tab.
    private var enumEditor: EnumLabelEditor? {
        guard objectRef.kind == .userType, objectRef.typeKind == .enumeration,
              let connection = DatabaseManager.shared.session(for: connectionId)?.connection
        else { return nil }
        return EnumLabelEditor(connection: connection, objectRef: objectRef)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: objectRef.kindIconName)
                .foregroundStyle(Color.accentColor)
            Text(objectRef.displayIdentity)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(objectRef.kindDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
            Spacer()
            if enumEditor?.canEdit != true {
                Text("Read Only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await loader.load(isRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Reload from the database"))
            .accessibilityLabel(String(localized: "Reload"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        case .failed(let message):
            ContentUnavailableView {
                Label("Source Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await loader.load() }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .loaded:
            VStack(spacing: 0) {
                if let editor = enumEditor, let type = loader.userType {
                    EnumLabelListView(
                        labels: loader.enumLabels,
                        canEdit: editor.canEdit,
                        canRename: editor.canRename(type),
                        onAdd: { label, placement in
                            try await editor.add(label: label, placement: placement, to: type)
                            await loader.load(isRefresh: true)
                        },
                        onRename: { oldLabel, newLabel in
                            try await editor.rename(oldLabel, to: newLabel, in: type)
                            await loader.load(isRefresh: true)
                        }
                    )
                    Divider()
                }
                ObjectSourceView(
                    source: loader.source,
                    databaseType: databaseType,
                    exportFileName: objectRef.suggestedFileName,
                    attributes: loader.attributes,
                    onOpenInEditor: { onOpenInEditor(loader.source) }
                )
            }
        }
    }
}
