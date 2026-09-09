//
//  AddRemoveControlGroup.swift
//  TablePro
//
//  The add/remove pair that sits under a list, which is where macOS puts a list's own +/-.
//  Shared by the structure editor's footer and the Users & Roles list.
//

import SwiftUI

struct AddRemoveControlGroup: View {
    let addLabel: String
    let removeLabel: String
    var canAdd = true
    var canRemove = true
    /// What the tooltip says. Defaults to the label; a withheld control sets it to the reason
    /// instead, which is the only place a disabled button has to explain itself.
    var addHelp: String?
    var removeHelp: String?
    var addIdentifier: String?
    var removeIdentifier: String?
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ControlGroup {
            Button(action: onAdd) {
                Label(addLabel, systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .help(addHelp ?? addLabel)
            .accessibilityLabel(addLabel)
            .accessibilityIdentifier(addIdentifier ?? "")
            .disabled(!canAdd)

            Button(action: onRemove) {
                Label(removeLabel, systemImage: "minus")
                    .labelStyle(.iconOnly)
            }
            .help(removeHelp ?? removeLabel)
            .accessibilityLabel(removeLabel)
            .accessibilityIdentifier(removeIdentifier ?? "")
            .disabled(!canRemove)
        }
        .controlGroupStyle(.navigation)
        .controlSize(.small)
        .fixedSize()
    }
}
