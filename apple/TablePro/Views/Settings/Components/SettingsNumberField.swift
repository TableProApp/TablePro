import SwiftUI

enum SettingsInvalidEntry: Equatable, Sendable {
    case clamp
    case reject(String)
}

enum SettingsIntegerInput {
    // Foundation's integer parsing reads "1,000" as 1 and "1e3" as 1000, so only a sign and decimal digits pass.
    static func parse(_ text: String) -> Int? {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var isNegative = false
        if let sign = digits.first, sign == "-" || sign == "\u{2212}" {
            isNegative = true
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        var magnitude = 0
        for character in digits {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  scalar.properties.numericType == .decimal,
                  let digit = character.wholeNumberValue else { return nil }
            let (shifted, shiftOverflow) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, addOverflow) = shifted.addingReportingOverflow(digit)
            guard !shiftOverflow, !addOverflow else { return nil }
            magnitude = sum
        }
        return isNegative ? -magnitude : magnitude
    }

    static func resolve(_ text: String, in range: ClosedRange<Int>, invalid: SettingsInvalidEntry) -> SettingsDraftResolution<Int> {
        guard let number = parse(text) else {
            switch invalid {
            case .clamp: return .revert
            case .reject(let message): return .reject(message)
            }
        }
        if range.contains(number) { return .accept(number) }
        switch invalid {
        case .clamp: return .accept(min(max(number, range.lowerBound), range.upperBound))
        case .reject(let message): return .reject(message)
        }
    }
}

struct SettingsNumberField: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let step: Int?
    private let unit: LocalizedStringResource?
    private let width: CGFloat
    private let invalid: SettingsInvalidEntry
    private let identifier: String?

    @State private var draft: SettingsTextDraft
    @FocusState private var isFocused: Bool

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int? = nil,
        unit: LocalizedStringResource? = nil,
        width: CGFloat = 64,
        invalid: SettingsInvalidEntry = .clamp,
        identifier: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.width = width
        self.invalid = invalid
        self.identifier = identifier
        _draft = State(initialValue: SettingsTextDraft(SettingsFormat.identifier(value.wrappedValue)))
    }

    var body: some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField(text: $draft.text, prompt: nil) { Text(title) }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand { draft.revert() }
                    .accessibilityIdentifier(identifier ?? "")

                if let step {
                    Stepper(value: stepperValue, in: range, step: step) { Text(title) }
                        .labelsHidden()
                        .accessibilityValue(Text(verbatim: spokenValue))
                        .accessibilityIdentifier(identifier.map { "\($0)-stepper" } ?? "")
                }

                if let unit {
                    Text(unit)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(title)
            if let error = draft.error {
                NoticeLabel(error, severity: .error)
            } else if let subtitle {
                Text(subtitle)
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
        .onChange(of: draft.text) { _ in
            draft.clearError(ifResolvedBy: resolve)
        }
        .onChange(of: value) { newValue in
            draft.resync(to: SettingsFormat.identifier(newValue))
        }
        .onAppear {
            draft.resync(to: SettingsFormat.identifier(value))
        }
        .onDisappear(perform: commit)
    }

    private var spokenValue: String {
        let number = SettingsFormat.identifier(value)
        guard let unit else { return number }
        return "\(number) \(String(localized: unit))"
    }

    private var stepperValue: Binding<Int> {
        Binding(
            get: { value },
            set: { stepped in
                let clamped = min(max(stepped, range.lowerBound), range.upperBound)
                if clamped != value { value = clamped }
                draft.settle(to: SettingsFormat.identifier(value))
            }
        )
    }

    private func resolve(_ text: String) -> SettingsDraftResolution<Int> {
        SettingsIntegerInput.resolve(text, in: range, invalid: invalid)
    }

    private func commit() {
        if let committed = draft.commit(to: value, resolve: resolve) {
            value = committed
        }
        if draft.error == nil {
            draft.settle(to: SettingsFormat.identifier(value))
        }
    }
}
