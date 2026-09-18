//
//  StartupCommandsEditor.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The multi-line text field the connection form uses for startup SQL, the pre-connect script and
/// the AI rules.
///
/// `movesFocusOnTab` is what makes it a form field rather than a code editor: Tab leaves for the
/// next control instead of inserting a tab character, which is how macOS expects a text view
/// inside a form to behave. Startup Commands and Pre-Connect Script trapped Tab; AI Rules did not.
struct StartupCommandsEditor: View {
    @Binding var text: String

    var body: some View {
        TextValueEditor(
            text: $text,
            font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            borderType: .bezelBorder,
            movesFocusOnTab: true
        )
    }
}
