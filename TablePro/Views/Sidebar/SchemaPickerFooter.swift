import Combine
import os
import SwiftUI
import TableProPluginKit

struct SchemaPickerFooter: View {
    let connectionId: UUID
    let databaseType: DatabaseType

    @Bindable private var schemaService = SchemaService.shared
    @State private var showSystemSchemas = false
    @State private var isSwitching = false

    private var currentSchema: String? {
        DatabaseManager.shared.session(for: connectionId)?.currentSchema
    }

    private var allSchemas: [String] {
        schemaService.schemas(for: connectionId)
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: databaseType))
    }

    private var userSchemas: [String] {
        allSchemas.filter { !systemSchemas.contains($0) }
    }

    private var visibleSystemSchemas: [String] {
        allSchemas.filter { systemSchemas.contains($0) }
    }

    var body: some View {
        Menu {
            ForEach(userSchemas, id: \.self) { schema in
                menuButton(for: schema)
            }

            if !visibleSystemSchemas.isEmpty {
                Divider()
                Toggle(String(localized: "Show System Schemas"), isOn: $showSystemSchemas)
                if showSystemSchemas {
                    ForEach(visibleSystemSchemas, id: \.self) { schema in
                        menuButton(for: schema)
                    }
                }
            }

            Divider()
            Button(String(localized: "Refresh")) {
                Task { await schemaService.invalidate(connectionId: connectionId) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(currentSchema ?? String(localized: "No schema"))
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isSwitching || allSchemas.isEmpty)
    }

    @ViewBuilder
    private func menuButton(for schema: String) -> some View {
        Button {
            select(schema: schema)
        } label: {
            if schema == currentSchema {
                Label(schema, systemImage: "checkmark")
            } else {
                Text(schema)
            }
        }
    }

    private func select(schema: String) {
        guard schema != currentSchema else { return }
        isSwitching = true
        Task {
            defer { isSwitching = false }
            do {
                try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)
                AppEvents.shared.currentSchemaChanged.send(connectionId)
            } catch {
                schemaSwitchLogger.error("Schema switch to \(schema, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private let schemaSwitchLogger = Logger(subsystem: "com.TablePro", category: "SchemaPicker")
