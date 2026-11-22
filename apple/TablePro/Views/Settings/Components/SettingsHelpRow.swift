import SwiftUI

struct SettingsHelpRow: View {
    private let text: Text

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) {
        self.text = Text(text)
    }

    var body: some View {
        text
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
