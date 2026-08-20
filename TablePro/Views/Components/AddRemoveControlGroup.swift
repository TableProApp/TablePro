//
//  AddRemoveControlGroup.swift
//  TablePro
//
//  The add/remove pair that sits under a list. Extracted from MainStatusBarView so the
//  structure footer and the Users & Roles list share one implementation.
//

import SwiftUI

struct AddRemoveControlGroup: View {
    let addLabel: String
    let removeLabel: String
    var canAdd = true
    var canRemove = true
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
            .help(addLabel)
            .accessibilityLabel(addLabel)
            .accessibilityIdentifier(addIdentifier ?? "")
            .disabled(!canAdd)

            Button(action: onRemove) {
                Label(removeLabel, systemImage: "minus")
                    .labelStyle(.iconOnly)
            }
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
            .accessibilityIdentifier(removeIdentifier ?? "")
            .disabled(!canRemove)
        }
        .controlGroupStyle(.navigation)
        .controlSize(.small)
        .fixedSize()
    }
}
