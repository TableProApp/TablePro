import SwiftUI

enum SettingsChoices {
    static func options<Value: Equatable>(_ fixed: [Value], including current: Value) -> (fixed: [Value], extra: Value?) {
        (fixed, fixed.contains(current) ? nil : current)
    }
}

// A pop-up whose stored value is off its list draws blank, so that value gets its own item after a divider.
struct SettingsChoiceItems<Value: Hashable, Title: View>: View {
    private let fixed: [Value]
    private let extra: Value?
    private let title: (Value) -> Title

    init(_ values: [Value], including current: Value, @ViewBuilder title: @escaping (Value) -> Title) {
        (fixed, extra) = SettingsChoices.options(values, including: current)
        self.title = title
    }

    var body: some View {
        ForEach(fixed, id: \.self) { value in
            title(value).tag(value)
        }
        if let extra {
            Divider()
            title(extra).tag(extra)
        }
    }
}
