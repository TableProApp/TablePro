import SwiftUI

struct CopyableCodeBlock: View {
    let text: String
    var isSecret = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                if isSecret {
                    ClipboardService.shared.writeSecretText(text)
                } else {
                    ClipboardService.shared.writeText(text)
                }
                AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(String(localized: "Copy"))
            .help(String(localized: "Copy to clipboard"))
        }
    }
}
