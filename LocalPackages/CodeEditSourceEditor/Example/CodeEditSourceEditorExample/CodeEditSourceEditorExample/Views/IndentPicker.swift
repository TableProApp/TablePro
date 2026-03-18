import SwiftUI
import CodeEditSourceEditor

struct IndentPicker: View {
    @Binding var indentOption: IndentOption
    let enabled: Bool

    private let possibleIndents: [IndentOption] = [
        .spaces(count: 4),
        .spaces(count: 2),
        .tab
    ]

    var body: some View {
        Picker(
            "Indent",
            selection: $indentOption
        ) {
            ForEach(possibleIndents, id: \.optionDescription) { indent in
                Text(indent.optionDescription)
                    .tag(indent)
            }
        }
        .labelsHidden()
        .disabled(!enabled)
    }
}

extension IndentOption {
    var optionDescription: String {
        switch self {
        case .spaces(count: let count):
            return "Spaces (\(count))"
        case .tab:
            return "Tab"
        }
    }
}

#Preview {
    IndentPicker(indentOption: .constant(.spaces(count: 4)), enabled: true)
}
