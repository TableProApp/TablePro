//
//  ResultSetMenu.swift
//  TablePro
//

import SwiftUI

/// A pull-down in the status bar rather than a strip of its own, which spent 32pt in every query tab, even with one result.
struct ResultSetMenu: View {
    let model: ResultSetMenuModel
    /// Spelled out where the bar has room, counted in figures where it does not.
    let isSpelledOut: Bool
    let onActivate: (UUID) -> Void
    let onTogglePin: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onCloseOthers: (UUID) -> Void

    var body: some View {
        Menu {
            ForEach(model.entries) { entry in
                Button {
                    onActivate(entry.id)
                } label: {
                    /// A checkmark on the active one and a pin glyph on the pinned ones, which is
                    /// the menu vocabulary for "this is current" and "this is held".
                    Label {
                        Text(entry.label)
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
                    onTogglePin(active.id)
                }

                Button(String(localized: "Close Result")) { onClose(active.id) }
                    .disabled(!model.canClose(active))

                Button(String(localized: "Close Other Results")) { onCloseOthers(active.id) }
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
