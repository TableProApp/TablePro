//
//  ResultSetMenu.swift
//  TablePro
//

import SwiftUI

struct ResultSetActions {
    let activate: (UUID) -> Void
    let togglePin: (UUID) -> Void
    let compare: (UUID) -> Void
    let close: (UUID) -> Void
    let closeOthers: (UUID) -> Void

    static var none: ResultSetActions {
        ResultSetActions(activate: { _ in }, togglePin: { _ in }, compare: { _ in }, close: { _ in }, closeOthers: { _ in })
    }
}

// Lists every result and acts on the current one. A tab row cannot do the second: no stock control tells which segment was right-clicked.
struct ResultSetMenu: View {
    let model: ResultSetMenuModel
    let isSpelledOut: Bool
    let actions: ResultSetActions

    var body: some View {
        Menu {
            ForEach(model.entries) { entry in
                Button {
                    actions.activate(entry.id)
                } label: {
                    Label {
                        Text(model.displayLabel(of: entry))
                    } icon: {
                        if entry.isActive {
                            Image(systemName: "checkmark")
                        } else if entry.isPinned {
                            Image(systemName: "pin.fill")
                        }
                    }
                }
            }

            if let active = model.activeEntry {
                Divider()

                Button(active.isPinned
                    ? String(localized: "Unpin Result")
                    : String(localized: "Pin Result")
                ) {
                    actions.togglePin(active.id)
                }

                Button(String(localized: "Compare Result With…")) { actions.compare(active.id) }
                    .disabled(!model.canCompare(active))

                Button(String(localized: "Close Result")) { actions.close(active.id) }
                    .disabled(!model.canClose(active))

                Button(String(localized: "Close Other Results")) { actions.closeOthers(active.id) }
                    .disabled(!model.canCloseOthers(active))
            }
        } label: {
            HStack(spacing: 4) {
                if model.activeEntry?.isPinned == true {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                }
                Text(isSpelledOut ? model.title : model.compactTitle)
            }
            .accessibilityLabel(model.title)
        }
        .menuStyle(.button)
        .accessoryBarStyle()
        .controlSize(.small)
        .fixedSize()
        .help(String(localized: "Choose which result this pane shows"))
        .accessibilityIdentifier("result-set-menu")
    }
}
