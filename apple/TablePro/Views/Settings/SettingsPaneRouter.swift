import SwiftUI

// The root of one retained pane host: the pane's own stack, its pages and its stack-level presentations.
internal struct SettingsPaneHost: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        content
            .environment(\.appServices, .live)
    }

    @ViewBuilder private var content: some View {
        switch context.pane {
        case .general:
            SettingsPaneStack(context: context) {
                GeneralSettingsEntry(context: context)
            } page: {
                GeneralSettingsPageEntry(route: $0, context: context)
            }
            .modifier(GeneralStackPresentations(context: context))
        case .appearance:
            SettingsPaneStack(context: context) {
                AppearanceSettingsEntry(context: context)
            } page: {
                AppearanceSettingsPageEntry(route: $0, context: context)
            }
            .modifier(AppearanceStackPresentations(context: context))
        case .notifications:
            SettingsPaneStack(context: context) {
                NotificationsSettingsEntry(context: context)
            } page: {
                NotificationsSettingsPageEntry(route: $0, context: context)
            }
            .modifier(NotificationsStackPresentations(context: context))
        case .keyboard:
            SettingsPaneStack(context: context) {
                KeyboardSettingsEntry(context: context)
            } page: {
                KeyboardSettingsPageEntry(route: $0, context: context)
            }
            .modifier(KeyboardStackPresentations(context: context))
        case .connections:
            SettingsPaneStack(context: context) {
                ConnectionsSettingsEntry(context: context)
            } page: {
                ConnectionsSettingsPageEntry(route: $0, context: context)
            }
            .modifier(ConnectionsStackPresentations(context: context))
        case .profiles:
            SettingsPaneStack(context: context) {
                ProfilesSettingsEntry(context: context)
            } page: {
                ProfilesSettingsPageEntry(route: $0, context: context)
            }
            .modifier(ProfilesStackPresentations(context: context))
        case .sidebar:
            SettingsPaneStack(context: context) {
                SidebarTabsSettingsEntry(context: context)
            } page: {
                SidebarTabsSettingsPageEntry(route: $0, context: context)
            }
            .modifier(SidebarTabsStackPresentations(context: context))
        case .editor:
            SettingsPaneStack(context: context) {
                EditorSettingsEntry(context: context)
            } page: {
                EditorSettingsPageEntry(route: $0, context: context)
            }
            .modifier(EditorStackPresentations(context: context))
        case .data:
            SettingsPaneStack(context: context) {
                DataSettingsEntry(context: context)
            } page: {
                DataSettingsPageEntry(route: $0, context: context)
            }
            .modifier(DataStackPresentations(context: context))
        case .ai:
            SettingsPaneStack(context: context) {
                AISettingsEntry(context: context)
            } page: {
                AISettingsPageEntry(route: $0, context: context)
            }
            .modifier(AIStackPresentations(context: context))
        case .mcp:
            SettingsPaneStack(context: context) {
                MCPSettingsEntry(context: context)
            } page: {
                MCPSettingsPageEntry(route: $0, context: context)
            }
            .modifier(MCPStackPresentations(context: context))
        case .plugins:
            SettingsPaneStack(context: context) {
                ExtensionsSettingsEntry(context: context)
            } page: {
                ExtensionsSettingsPageEntry(route: $0, context: context)
            }
            .modifier(ExtensionsStackPresentations(context: context))
        case .sync:
            SettingsPaneStack(context: context) {
                SyncSettingsEntry(context: context)
            } page: {
                SyncSettingsPageEntry(route: $0, context: context)
            }
            .modifier(SyncStackPresentations(context: context))
        case .account:
            SettingsPaneStack(context: context) {
                AccountSettingsEntry(context: context)
            } page: {
                AccountSettingsPageEntry(route: $0, context: context)
            }
            .modifier(AccountStackPresentations(context: context))
        }
    }
}

// One navigationDestination per stack, outside any Form or List, so every SettingsRoute link resolves.
private struct SettingsPaneStack<Root: View, Page: View>: View {
    private let context: SettingsPaneContext
    @ObservedObject private var path: SettingsPanePath
    private let root: Root
    private let page: (SettingsRoute) -> Page

    init(
        context: SettingsPaneContext,
        @ViewBuilder root: () -> Root,
        @ViewBuilder page: @escaping (SettingsRoute) -> Page
    ) {
        self.context = context
        self._path = ObservedObject(wrappedValue: context.path)
        self.root = root()
        self.page = page
    }

    var body: some View {
        NavigationStack(path: routes) {
            root
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationDestination(for: SettingsRoute.self) { route in
                    page(route)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }
    }

    private var routes: Binding<[SettingsRoute]> {
        let context = context
        return Binding(
            get: { context.path.routes },
            set: { context.navigation.setRoutes($0, for: context.pane) }
        )
    }
}

// Stands in for a page whose pane has not moved to the route-based pages yet.
internal struct SettingsPagePlaceholder: View {
    internal let title: String

    internal var body: some View {
        Form {
            Section {
                Text(verbatim: title)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
