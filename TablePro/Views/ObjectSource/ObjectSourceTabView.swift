//
//  ObjectSourceTabView.swift
//  TablePro
//
//  Tab showing the source of one stored procedure, function or trigger.
//

import SwiftUI
import TableProPluginKit

@MainActor
@Observable
final class ObjectSourceLoader {
    enum State {
        case loading
        case loaded(source: String, attributes: [ObjectAttribute])
        case failed(String)
    }

    private(set) var state: State = .loading

    private let connectionId: UUID
    private let objectRef: DatabaseObjectRef

    init(connectionId: UUID, objectRef: DatabaseObjectRef) {
        self.connectionId = connectionId
        self.objectRef = objectRef
    }

    var source: String {
        if case .loaded(let source, _) = state { return source }
        return ""
    }

    var attributes: [ObjectAttribute] {
        if case .loaded(_, let attributes) = state { return attributes }
        return []
    }

    /// A refresh fetches before it commits, so a failed reload leaves the definition the reader is
    /// looking at on screen rather than replacing it with an error.
    func load(isRefresh: Bool = false) async {
        if !isRefresh { state = .loading }
        do {
            let fetched = try await fetch()
            state = .loaded(source: fetched.source, attributes: fetched.attributes)
        } catch is CancellationError {
        } catch {
            guard case .loaded = state, isRefresh else {
                state = .failed(error.localizedDescription)
                return
            }
        }
    }

    /// One round trip. Re-listing the schema to recover the attributes cost a full catalog scan
    /// per open and per reload, for values the sidebar's listing already carried into the ref.
    private func fetch() async throws -> (source: String, attributes: [ObjectAttribute]) {
        let scope = DatabaseScope(
            connectionId: connectionId,
            database: objectRef.database,
            schema: objectRef.schema
        )
        let source = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { [objectRef] driver in
            switch objectRef.kind {
            case .procedure, .function:
                guard let routine = objectRef.routine else {
                    throw PluginObjectSourceError.unsupported(objectRef.name)
                }
                return try await driver.fetchRoutineDDL(routine)
            case .trigger:
                guard let trigger = objectRef.trigger else {
                    throw PluginObjectSourceError.unsupported(objectRef.name)
                }
                return try await driver.fetchTriggerDDL(trigger)
            }
        }
        return (source, objectRef.attributes)
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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: objectRef.kind.iconName)
                .foregroundStyle(Color.accentColor)
            Text(objectRef.displayIdentity)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(objectRef.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
            Spacer()
            Text("Read Only")
                .font(.caption)
                .foregroundStyle(.secondary)
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
