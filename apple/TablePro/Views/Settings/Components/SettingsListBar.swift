import AppKit
import SwiftUI

// Only the row: SettingsFullPageList draws the bar's divider and fill inside the list's border.
struct SettingsListBar<AddMenu: View, Actions: View, Leading: View, Trailing: View>: View {
    private struct AddRemove {
        let addLabel: String
        let removeLabel: String
        let canAdd: Bool
        let canRemove: Bool
        let addHelp: String?
        let removeHelp: String?
        let addIdentifier: String?
        let removeIdentifier: String?
        // nil when + opens the add menu.
        let onAdd: (() -> Void)?
        let onRemove: () -> Void
    }

    private static var slotInset: CGFloat { 8 }

    private let addRemove: AddRemove?
    private let addMenu: AddMenu
    private let actionsLabel: String
    private let actionsIdentifier: String?
    private let actions: Actions
    private let leading: Leading
    private let trailing: Trailing

    private init(
        addRemove: AddRemove?,
        addMenu: AddMenu,
        actionsLabel: String,
        actionsIdentifier: String?,
        actions: Actions,
        leading: Leading,
        trailing: Trailing
    ) {
        self.addRemove = addRemove
        self.addMenu = addMenu
        self.actionsLabel = actionsLabel
        self.actionsIdentifier = actionsIdentifier
        self.actions = actions
        self.leading = leading
        self.trailing = trailing
    }

    init(
        addLabel: String,
        removeLabel: String,
        canAdd: Bool = true,
        canRemove: Bool = true,
        addHelp: String? = nil,
        removeHelp: String? = nil,
        addIdentifier: String? = nil,
        removeIdentifier: String? = nil,
        @ViewBuilder addMenu: () -> AddMenu,
        onRemove: @escaping () -> Void,
        actionsLabel: String = String(localized: "Actions"),
        actionsIdentifier: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.init(
            addRemove: AddRemove(
                addLabel: addLabel,
                removeLabel: removeLabel,
                canAdd: canAdd,
                canRemove: canRemove,
                addHelp: addHelp,
                removeHelp: removeHelp,
                addIdentifier: addIdentifier,
                removeIdentifier: removeIdentifier,
                onAdd: nil,
                onRemove: onRemove
            ),
            addMenu: addMenu(),
            actionsLabel: actionsLabel,
            actionsIdentifier: actionsIdentifier,
            actions: actions(),
            leading: leading(),
            trailing: trailing()
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if let addRemove {
                addControl(addRemove)
                ListBarSeparator()
                ListBarButton(
                    label: addRemove.removeLabel,
                    systemImage: "minus",
                    help: addRemove.removeHelp,
                    identifier: addRemove.removeIdentifier,
                    action: addRemove.onRemove
                )
                .disabled(!addRemove.canRemove)
            }

            if Self.isPresent(Actions.self) {
                if addRemove != nil {
                    ListBarSeparator()
                }
                SettingsListBarMenu(
                    label: actionsLabel,
                    systemImage: "ellipsis.circle",
                    help: nil,
                    identifier: actionsIdentifier
                ) {
                    actions
                }
            }

            if Self.isPresent(Leading.self) {
                slot(leading)
            }

            Spacer(minLength: 0)

            if Self.isPresent(Trailing.self) {
                slot(trailing)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func addControl(_ addRemove: AddRemove) -> some View {
        if let onAdd = addRemove.onAdd {
            ListBarButton(
                label: addRemove.addLabel,
                systemImage: "plus",
                help: addRemove.addHelp,
                identifier: addRemove.addIdentifier,
                action: onAdd
            )
            .disabled(!addRemove.canAdd)
        } else {
            SettingsListBarMenu(
                label: addRemove.addLabel,
                systemImage: "plus",
                help: addRemove.addHelp,
                identifier: addRemove.addIdentifier
            ) {
                addMenu
            }
            .disabled(!addRemove.canAdd)
        }
    }

    // A regular push button is taller than the 23pt bar.
    private func slot(_ content: some View) -> some View {
        content
            .font(.subheadline)
            .controlSize(.small)
            .lineLimit(1)
            .padding(.horizontal, Self.slotInset)
    }

    private static func isPresent<V: View>(_: V.Type) -> Bool {
        V.self != EmptyView.self
    }
}

extension SettingsListBar where AddMenu == EmptyView {
    init(
        addLabel: String,
        removeLabel: String,
        canAdd: Bool = true,
        canRemove: Bool = true,
        addHelp: String? = nil,
        removeHelp: String? = nil,
        addIdentifier: String? = nil,
        removeIdentifier: String? = nil,
        onAdd: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        actionsLabel: String = String(localized: "Actions"),
        actionsIdentifier: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.init(
            addRemove: AddRemove(
                addLabel: addLabel,
                removeLabel: removeLabel,
                canAdd: canAdd,
                canRemove: canRemove,
                addHelp: addHelp,
                removeHelp: removeHelp,
                addIdentifier: addIdentifier,
                removeIdentifier: removeIdentifier,
                onAdd: onAdd,
                onRemove: onRemove
            ),
            addMenu: EmptyView(),
            actionsLabel: actionsLabel,
            actionsIdentifier: actionsIdentifier,
            actions: actions(),
            leading: leading(),
            trailing: trailing()
        )
    }
}

extension SettingsListBar where AddMenu == EmptyView, Actions == EmptyView {
    init(
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.init(
            addRemove: nil,
            addMenu: EmptyView(),
            actionsLabel: "",
            actionsIdentifier: nil,
            actions: EmptyView(),
            leading: leading(),
            trailing: trailing()
        )
    }
}

private struct SettingsListBarMenu<Items: View>: View {
    let label: String
    let systemImage: String
    let help: String?
    let identifier: String?
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .frame(width: ListBarMetrics.buttonWidth, height: ListBarMetrics.contentHeight)
                .contentShape(Rectangle())
        }
        // Plain, not borderless: a borderless menu is an NSPopUpButton that ignores this label's font, color and frame.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}
