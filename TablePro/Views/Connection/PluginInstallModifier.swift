import SwiftUI

private struct PluginInstallModifier<Item>: ViewModifier {
    @Binding var item: Item?
    let databaseType: KeyPath<Item, DatabaseType>
    let onInstalled: (Item) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Plugin Not Installed"),
                isPresented: Binding(
                    get: { item != nil },
                    set: { if !$0 { item = nil } }
                ),
                presenting: item
            ) { pending in
                Button(String(localized: "Install")) {
                    install(pending)
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: { pending in
                Text(String(
                    format: String(localized: "The %@ plugin is not installed. Would you like to install it?"),
                    pending[keyPath: databaseType].displayName
                ))
            }
    }

    private func install(_ pending: Item) {
        let type = pending[keyPath: databaseType]
        Task {
            let isInstalled = await PluginInstallPrompt.run(pluginName: type.displayName, window: nil) { progress in
                try await PluginManager.shared.installMissingPlugin(for: type, progress: progress)
            }
            if isInstalled {
                onInstalled(pending)
            }
        }
    }
}

internal extension View {
    func pluginInstallPrompt<Item>(
        for item: Binding<Item?>,
        type databaseType: KeyPath<Item, DatabaseType>,
        onInstalled: @escaping (Item) -> Void
    ) -> some View {
        modifier(PluginInstallModifier(item: item, databaseType: databaseType, onInstalled: onInstalled))
    }
}
