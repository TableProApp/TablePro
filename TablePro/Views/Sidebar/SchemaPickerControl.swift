//
//  SchemaPickerControl.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The active schema, at the foot of the object list, for engines that browse one schema at a time.
///
/// The toolbar's scope chip carries the same value and is the control the HIG points at, because a
/// window can be positioned so its bottom edge is off screen. This one stays because the flat object
/// list is scoped to the active schema, so the schema belongs beside the list it filters.
struct SchemaPickerControl: View {
    let connectionId: UUID
    let databaseType: DatabaseType
    let coordinator: MainContentCoordinator?

    @Bindable private var schemaService = SchemaService.shared
    @Bindable private var databaseManager = DatabaseManager.shared
    @State private var showSystemSchemas = false

    private var currentSchema: String? {
        databaseManager.session(for: connectionId)?.browseSchema
    }

    private var sections: SchemaMenuModel.Sections {
        SchemaMenuModel.sections(
            all: schemaService.schemas(for: connectionId),
            system: Set(PluginManager.shared.systemSchemaNames(for: databaseType))
        )
    }

    private var entityName: String {
        PluginManager.shared.schemaEntityName(for: databaseType)
    }

    private var selectedSchema: Binding<String> {
        Binding(
            get: { currentSchema ?? "" },
            set: { newValue in
                guard !newValue.isEmpty, newValue != currentSchema else { return }
                Task { await coordinator?.switchSchema(to: newValue) }
            }
        )
    }

    static func shouldShow(schemaCount: Int) -> Bool {
        schemaCount > 0
    }

    var body: some View {
        let sections = sections
        if Self.shouldShow(schemaCount: sections.user.count + sections.system.count) {
            Menu {
                Picker(entityName, selection: selectedSchema) {
                    ForEach(sections.user, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                    if showSystemSchemas {
                        ForEach(sections.system, id: \.self) { schema in
                            Text(schema).tag(schema)
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if !sections.system.isEmpty {
                    Divider()
                    Toggle(
                        String(format: String(localized: "Show System %@s"), entityName),
                        isOn: $showSystemSchemas
                    )
                }

                Divider()
                Button(String(localized: "Refresh")) {
                    Task { await schemaService.refresh(connectionId: connectionId) }
                }
            } label: {
                Text(currentSchema ?? String(format: String(localized: "Select %@"), entityName.lowercased()))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(String(format: String(localized: "Current %@"), entityName.lowercased()))
        }
    }
}
