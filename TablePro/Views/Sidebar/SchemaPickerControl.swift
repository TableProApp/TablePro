import SwiftUI
import TableProPluginKit

struct SchemaPickerControl: View {
    let connectionId: UUID
    let databaseType: DatabaseType
    let coordinator: MainContentCoordinator?

    @Bindable private var schemaService = SchemaService.shared
    @Bindable private var databaseManager = DatabaseManager.shared
    @State private var showSystemSchemas = false

    private var currentSchema: String? {
        databaseManager.session(for: connectionId)?.currentSchema
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

    private var selectedSchema: Binding<String> {
        Binding(
            get: { currentSchema ?? "" },
            set: { newValue in
                guard !newValue.isEmpty, newValue != currentSchema else { return }
                Task { await coordinator?.switchSchema(to: newValue) }
            }
        )
    }

    var body: some View {
        if allSchemas.count > 1 {
            Menu {
                Picker(String(localized: "Schema"), selection: selectedSchema) {
                    ForEach(userSchemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                    if showSystemSchemas {
                        ForEach(visibleSystemSchemas, id: \.self) { schema in
                            Text(schema).tag(schema)
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if !visibleSystemSchemas.isEmpty {
                    Divider()
                    Toggle(String(localized: "Show System Schemas"), isOn: $showSystemSchemas)
                }

                Divider()
                Button(String(localized: "Refresh")) {
                    Task { await schemaService.refresh(connectionId: connectionId) }
                }
            } label: {
                Text(currentSchema ?? String(localized: "Select schema"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(String(localized: "Current schema"))
        }
    }
}
