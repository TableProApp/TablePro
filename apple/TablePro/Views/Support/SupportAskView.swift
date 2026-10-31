//
//  SupportAskView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The license ask, shown as a sheet once someone has used TablePro on 30 days.
///
/// It says what the Support window says, once, and takes any answer: buying, saying TablePro is
/// for personal use, which quiets it for a year, or not now. Nothing is withheld whichever is
/// chosen.
struct SupportAskView: View {
    let usageDays: Int
    let answer: (SupportAskAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("You've used TablePro on \(usageDays) days")
                        .font(.headline)

                    Text("TablePro is free for everyone, at work too, and none of it will become paid.")
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "If TablePro is part of your work now, please buy a license. Licenses are what pay for the next release."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Button("I Use It Personally") { answer(.personal) }
                    .accessibilityIdentifier("support-ask-personal")

                Spacer()

                Button("Not Now") { answer(.notNow) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("support-ask-not-now")

                Button("Buy a License") { answer(.buy) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("support-ask-buy")
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SupportAskView(usageDays: 30) { _ in }
}
