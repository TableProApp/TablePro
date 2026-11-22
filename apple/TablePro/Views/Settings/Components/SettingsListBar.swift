import SwiftUI

struct SettingsListBar<Actions: View, Leading: View, Trailing: View>: View {
    private let addRemove: AddRemoveControlGroup?
    private let actionsLabel: String
    private let actionsIdentifier: String?
    private let actions: Actions
    private let leading: Leading
    private let trailing: Trailing

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
        addRemove = AddRemoveControlGroup(
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
        )
        self.actionsLabel = actionsLabel
        self.actionsIdentifier = actionsIdentifier
        self.actions = actions()
        self.leading = leading()
        self.trailing = trailing()
    }

    init(
        actionsLabel: String = String(localized: "Actions"),
        actionsIdentifier: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        addRemove = nil
        self.actionsLabel = actionsLabel
        self.actionsIdentifier = actionsIdentifier
        self.actions = actions()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let addRemove {
                addRemove
            }

            if Actions.self != EmptyView.self {
                actionsMenu
            }

            leading

            Spacer(minLength: 0)

            trailing
        }
    }

    // A label inside an icon-only Menu's label closure leaves VoiceOver reading "More"; .contain plus a label on the menu names it.
    private var actionsMenu: some View {
        Menu {
            actions
        } label: {
            Label(actionsLabel, systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(actionsLabel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(actionsLabel)
        .accessibilityIdentifier(actionsIdentifier ?? "")
    }
}
