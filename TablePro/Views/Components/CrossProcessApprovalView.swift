import AppKit
import SwiftUI

internal struct CrossProcessApprovalView: View {
    internal static let width: CGFloat = 440

    let title: String
    let message: String
    let allowTitle: String
    let denyTitle: String
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .lineLimit(20)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DialogFooter {
                Button(allowTitle) { onDecide(true) }

                Button(denyTitle, role: .cancel) { onDecide(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }
}
