import SwiftUI

// Records the choice only; it runs once the guide closes, so the options step still comes first.
internal struct SetupGuideFirstConnectionStep: View {
    @ObservedObject var model: SetupGuideModel

    @FocusState private var focused: SetupGuideFirstConnection??

    private static let choices: [SetupGuideFirstConnection?] = [nil, .newConnection, .sample]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Self.choices, id: \.self) { choice in
                card(choice)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "When you finish"))
        .accessibilityIdentifier("setup-guide-first-connection")
        .modifier(SetupGuideArrowKeys(move: move))
    }

    private func card(_ choice: SetupGuideFirstConnection?) -> some View {
        let isSelected = model.recorded == choice
        let title = title(for: choice)
        let detail = detail(for: choice)
        return Button {
            select(choice)
        } label: {
            SetupGuideCardLabel(symbol: symbol(for: choice), title: title, detail: detail)
        }
        .buttonStyle(SetupGuideChoiceButtonStyle(isSelected: isSelected))
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.primary() })
        .focused($focused, equals: .some(choice))
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("setup-guide-first-connection-\(Self.identifier(for: choice))")
    }

    private func select(_ choice: SetupGuideFirstConnection?) {
        guard choice != model.recorded else { return }
        model.recorded = choice
    }

    private func move(_ direction: SetupGuideArrowKeys.Direction) -> Bool {
        guard direction == .up || direction == .down else { return false }
        let current = focused ?? model.recorded
        guard let index = Self.choices.firstIndex(of: current) else { return false }
        let next = Self.choices[min(max(index + (direction == .up ? -1 : 1), 0), Self.choices.count - 1)]
        select(next)
        focused = .some(next)
        return true
    }

    private func title(for choice: SetupGuideFirstConnection?) -> String {
        switch choice {
        case .newConnection: SetupGuideOriginStep.title(for: .newConnection)
        case .sample: SetupGuideOriginStep.title(for: .sample)
        case nil:
            switch model.importedIds.count {
            case 0: String(localized: "Nothing for Now")
            case 1: String(localized: "Open the Imported Connection")
            default: String(localized: "Show the Imported Connections")
            }
        }
    }

    private func detail(for choice: SetupGuideFirstConnection?) -> String {
        switch choice {
        case .newConnection: SetupGuideOriginStep.detail(for: .newConnection)
        case .sample: SetupGuideOriginStep.detail(for: .sample)
        case nil:
            switch model.importedIds.count {
            case 0: String(localized: "Finish on the Welcome window")
            case 1: String(localized: "Connects when you finish")
            default: String(localized: "Selects them on the Welcome window")
            }
        }
    }

    private func symbol(for choice: SetupGuideFirstConnection?) -> String {
        switch choice {
        case .newConnection: SetupGuideOriginStep.symbol(for: .newConnection)
        case .sample: SetupGuideOriginStep.symbol(for: .sample)
        case nil:
            switch model.importedIds.count {
            case 0: "minus.circle"
            case 1: "arrow.right.circle"
            default: "list.bullet.circle"
            }
        }
    }

    private static func identifier(for choice: SetupGuideFirstConnection?) -> String {
        switch choice {
        case .newConnection: "new-connection"
        case .sample: "sample"
        case nil: "nothing"
        }
    }
}
