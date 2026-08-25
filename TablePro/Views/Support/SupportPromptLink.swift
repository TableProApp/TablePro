//
//  SupportPromptLink.swift
//  TablePro
//

import SwiftUI

/// A standing link to the support screen, shown only to someone who has not bought a license.
///
/// It never interrupts, never counts anything down, and cannot be dismissed, because there is
/// nothing to dismiss: it is a line of text that opens a window when clicked. It disappears on
/// its own the moment a license is active.
struct SupportPromptLink: View {
    private let licenseManager = LicenseManager.shared

    @ViewBuilder
    var body: some View {
        if licenseManager.supportAudience == .prospect {
            Button {
                SupportWindowController.present()
            } label: {
                Text("Support TablePro")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("support-prompt-link")
        }
    }
}

#Preview {
    SupportPromptLink()
        .padding()
}
