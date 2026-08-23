//
//  ConnectionStatusView.swift
//  TablePro
//
//  Central toolbar component displaying database type, version,
//  connection name, and connection state indicator.
//

import SwiftUI
import TableProPluginKit

/// Main connection status display for the toolbar center
struct ConnectionStatusView: View {
    let databaseType: DatabaseType
    let databaseVersion: String?
    let scopeComponents: [ConnectionScopeComponent]
    let connectionName: String
    let displayColor: Color
    var safeModeLevel: SafeModeLevel = .silent
    /// The chooser each component opens needs a live connection, and a component anchors its own
    /// popover so the list appears against the word it belongs to rather than against the toolbar
    /// button at the other end of the titlebar (#2194).
    weak var coordinator: MainContentCoordinator?

    @ScaledMetric private var engineIconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            connectionIdentitySection

            if !scopeComponents.isEmpty {
                Divider()
                    .frame(height: 12)

                scopeSection
            }
        }
    }

    // MARK: - Subviews

    private var connectionIdentitySection: some View {
        HStack(spacing: 6) {
            databaseType.iconImage
                .renderingMode(.template)
                .foregroundStyle(displayColor)
                .frame(width: engineIconSize, height: engineIconSize)

            Text(connectionName)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help(connectionTooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connectionAccessibilityLabel)
    }

    /// Nested scopes read outermost first with a chevron between them, the way Xcode separates its
    /// scheme from its destination. Each component owns its own label, tooltip and chooser, so the
    /// word on screen and the list that opens always name the same thing.
    private var scopeSection: some View {
        HStack(spacing: 4) {
            ForEach(scopeComponents) { component in
                if component.id != scopeComponents.first?.id {
                    Image(systemName: "chevron.compact.right")
                        .imageScale(.small)
                        .foregroundStyle(ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI)
                        .accessibilityHidden(true)
                }
                scopeComponentView(component)
            }
        }
    }

    @ViewBuilder
    private func scopeComponentView(_ component: ConnectionScopeComponent) -> some View {
        if component.isSwitchable {
            Button {
                coordinator?.commandActions?.openScopeSwitcher(component.kind)
            } label: {
                scopeLabel(component)
            }
            .buttonStyle(.plain)
            .help(switchableTooltip(component))
            .accessibilityLabel(accessibilityLabel(component))
            /// This chip keeps a SwiftUI popover, and correctly so: it lives in the centred status
            /// item, has no menu command and no shortcut, so there is no route that can fire it
            /// while its own view is off screen. Dismissal clears the state that presents it,
            /// which is what `@Environment(\.dismiss)` used to do before the switcher content
            /// started taking an explicit closure.
            .popover(isPresented: presentation(of: component.kind), arrowEdge: .bottom) {
                DatabaseSwitcherPopoverHost(
                    coordinator: coordinator,
                    target: component.kind,
                    dismiss: { [weak coordinator] in coordinator?.presentedScopeSwitcher = nil }
                )
            }
        } else {
            scopeLabel(component)
                .help(staticTooltip(component))
                .accessibilityLabel(accessibilityLabel(component))
        }
    }

    private func presentation(of kind: ContainerSwitchTarget) -> Binding<Bool> {
        Binding(
            get: { coordinator?.presentedScopeSwitcher == kind },
            set: { [weak coordinator] isShown in
                guard !isShown else { return }
                if coordinator?.presentedScopeSwitcher == kind {
                    coordinator?.presentedScopeSwitcher = nil
                }
            }
        )
    }

    private func scopeLabel(_ component: ConnectionScopeComponent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon(for: component.kind))
                .imageScale(.small)
                .foregroundStyle(ThemeEngine.shared.colors.toolbar.secondaryTextSwiftUI)
                .accessibilityHidden(true)

            Text(component.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func icon(for kind: ContainerSwitchTarget) -> String {
        switch kind {
        case .database: return "cylinder"
        case .schema: return "square.stack.3d.up"
        }
    }

    private func staticTooltip(_ component: ConnectionScopeComponent) -> String {
        String(format: String(localized: "%1$@: %2$@"), component.label, component.name)
    }

    /// Only the outermost scope has a shortcut, so the inner one says nothing about a key rather
    /// than advertising one that does nothing. The key comes from the user's own binding, because a
    /// hint that names a shortcut nobody bound is the same defect in a smaller place (#2185).
    private func switchableTooltip(_ component: ConnectionScopeComponent) -> String {
        let scope = component.label.lowercased()
        let base = safeModeLevel == .readOnly
            ? String(format: String(localized: "Current %1$@: %2$@ (read only)"), scope, component.name)
            : String(format: String(localized: "Current %1$@: %2$@"), scope, component.name)
        guard component.kind == scopeComponents.first?.kind else { return base }
        return AppSettingsManager.shared.keyboard.shortcutHint(base, for: .openDatabase)
    }

    private func accessibilityLabel(_ component: ConnectionScopeComponent) -> String {
        String(format: String(localized: "Current %1$@: %2$@"), component.label.lowercased(), component.name)
    }

    // MARK: - Computed Properties

    private var formattedDatabaseInfo: String {
        if let version = databaseVersion, !version.isEmpty {
            return "\(databaseType.rawValue) \(version)"
        }
        return databaseType.rawValue
    }

    private var connectionTooltip: String {
        String(format: String(localized: "%@ • %@"), connectionName, formattedDatabaseInfo)
    }

    private var connectionAccessibilityLabel: String {
        String(format: String(localized: "Connection: %@, %@"), connectionName, formattedDatabaseInfo)
    }
}

// MARK: - Preview

private func previewComponent(
    _ kind: ContainerSwitchTarget,
    _ name: String,
    _ label: String,
    switchable: Bool = true
) -> ConnectionScopeComponent {
    ConnectionScopeComponent(kind: kind, name: name, label: label, isSwitchable: switchable)
}

#Preview("MariaDB") {
    ConnectionStatusView(
        databaseType: .mariadb,
        databaseVersion: "11.1.2",
        scopeComponents: [previewComponent(.database, "production_db", "Database")],
        connectionName: "Production Database",
        displayColor: .cyan
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("MySQL") {
    ConnectionStatusView(
        databaseType: .mysql,
        databaseVersion: "8.0.35",
        scopeComponents: [previewComponent(.database, "dev_db", "Database")],
        connectionName: "Development",
        displayColor: .orange
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("PostgreSQL Dark") {
    ConnectionStatusView(
        databaseType: .postgresql,
        databaseVersion: "16.1",
        scopeComponents: [
            previewComponent(.database, "analytics", "Database"),
            previewComponent(.schema, "public", "Schema"),
        ],
        connectionName: "Analytics DB",
        displayColor: .blue
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}

#Preview("SQLite") {
    ConnectionStatusView(
        databaseType: .sqlite,
        databaseVersion: "3.45.0",
        scopeComponents: [previewComponent(.database, "chinook.db", "Database", switchable: false)],
        connectionName: "Local",
        displayColor: .green
    )
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
