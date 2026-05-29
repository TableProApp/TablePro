import AppKit
import os
import SwiftUI
import TableProPluginKit

struct SchemaPickerFooter: View {
    let connectionId: UUID
    let databaseType: DatabaseType

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

    var body: some View {
        if allSchemas.count > 1 {
            VStack(spacing: 0) {
                Divider()
                SchemaPopUpButton(
                    title: currentSchema ?? String(localized: "Select schema"),
                    userSchemas: userSchemas,
                    systemSchemas: visibleSystemSchemas,
                    showSystemSchemas: $showSystemSchemas,
                    currentSchema: currentSchema,
                    onSelect: select(schema:),
                    onRefresh: { Task { await schemaService.refresh(connectionId: connectionId) } }
                )
                .padding(8)
            }
        }
    }

    private func select(schema: String) {
        guard schema != currentSchema else { return }
        Task {
            do {
                try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)
            } catch {
                schemaPickerLogger.error("Schema switch to \(schema, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private let schemaPickerLogger = Logger(subsystem: "com.TablePro", category: "SchemaPicker")

private struct SchemaPopUpButton: NSViewRepresentable {
    let title: String
    let userSchemas: [String]
    let systemSchemas: [String]
    @Binding var showSystemSchemas: Bool
    let currentSchema: String?
    let onSelect: (String) -> Void
    let onRefresh: () -> Void

    private var fingerprint: MenuFingerprint {
        MenuFingerprint(
            title: title,
            userSchemas: userSchemas,
            systemSchemas: systemSchemas,
            showSystemSchemas: showSystemSchemas,
            currentSchema: currentSchema
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.preferredEdge = .maxY
        context.coordinator.lastFingerprint = fingerprint
        rebuildMenu(button: button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let next = fingerprint
        guard context.coordinator.lastFingerprint != next else { return }
        context.coordinator.lastFingerprint = next
        rebuildMenu(button: button, context: context)
    }

    private func rebuildMenu(button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))

        for schema in userSchemas {
            menu.addItem(schemaItem(schema, coordinator: context.coordinator))
        }

        if !systemSchemas.isEmpty {
            menu.addItem(.separator())
            let toggleItem = NSMenuItem(
                title: String(localized: "Show System Schemas"),
                action: #selector(Coordinator.toggleSystem(_:)),
                keyEquivalent: ""
            )
            toggleItem.target = context.coordinator
            toggleItem.state = showSystemSchemas ? .on : .off
            menu.addItem(toggleItem)

            if showSystemSchemas {
                for schema in systemSchemas {
                    menu.addItem(schemaItem(schema, coordinator: context.coordinator))
                }
            }
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: String(localized: "Refresh"),
            action: #selector(Coordinator.refreshTriggered(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = context.coordinator
        menu.addItem(refreshItem)

        button.menu = menu
    }

    private func schemaItem(_ schema: String, coordinator: Coordinator) -> NSMenuItem {
        let item = NSMenuItem(
            title: schema,
            action: #selector(Coordinator.schemaSelected(_:)),
            keyEquivalent: ""
        )
        item.target = coordinator
        item.representedObject = schema
        item.state = schema == currentSchema ? .on : .off
        return item
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SchemaPopUpButton
        var lastFingerprint: MenuFingerprint?

        init(parent: SchemaPopUpButton) {
            self.parent = parent
        }

        @objc func schemaSelected(_ sender: NSMenuItem) {
            guard let schema = sender.representedObject as? String else { return }
            parent.onSelect(schema)
        }

        @objc func toggleSystem(_ sender: NSMenuItem) {
            parent.showSystemSchemas.toggle()
        }

        @objc func refreshTriggered(_ sender: NSMenuItem) {
            parent.onRefresh()
        }
    }

    struct MenuFingerprint: Equatable {
        let title: String
        let userSchemas: [String]
        let systemSchemas: [String]
        let showSystemSchemas: Bool
        let currentSchema: String?
    }
}
