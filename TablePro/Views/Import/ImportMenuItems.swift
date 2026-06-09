//
//  ImportMenuItems.swift
//  TablePro
//

import SwiftUI

struct ImportMenuItems: View {
    let formats: [ImportFormatOption]
    let isDisabled: Bool
    let shortcut: KeyboardShortcut?
    let action: (String) -> Void

    var body: some View {
        if formats.isEmpty {
            Button("Import\u{2026}") {}
                .disabled(true)
        } else if formats.count == 1, let only = formats.first {
            Button(only.standaloneLabel) { action(only.id) }
                .optionalKeyboardShortcut(shortcut)
                .disabled(isDisabled)
        } else {
            Menu("Import") {
                ForEach(formats) { format in
                    Button(format.submenuLabel) { action(format.id) }
                        .optionalKeyboardShortcut(format.id == formats.first?.id ? shortcut : nil)
                }
            }
            .disabled(isDisabled)
        }
    }
}
