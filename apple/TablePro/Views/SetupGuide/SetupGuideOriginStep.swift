import SwiftUI

internal struct SetupGuideOriginStep: View {
    @ObservedObject var model: SetupGuideModel

    @FocusState private var focused: SetupGuideOrigin?

    private static let main: [SetupGuideOrigin] = [.command(.otherApp), .newConnection, .sample]
    private static let compact: [SetupGuideOrigin] = [
        .command(.connectionsFile), .command(.url), .command(.aws), .command(.projectFolder),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                ForEach(Self.main, id: \.self) { origin in
                    card(origin, size: .row)
                }
            }
            Text(verbatim: String(localized: "Other Ways to Import"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    card(Self.compact[0], size: .compact)
                    card(Self.compact[1], size: .compact)
                }
                GridRow {
                    card(Self.compact[2], size: .compact)
                    card(Self.compact[3], size: .compact)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "How to start"))
        .modifier(SetupGuideArrowKeys(move: move))
    }

    private func card(_ origin: SetupGuideOrigin, size: SetupGuideCardSize) -> some View {
        let isSelected = model.origin == origin
        let title = Self.title(for: origin)
        let detail = Self.detail(for: origin, foundApps: model.foundApps)
        return Button {
            select(origin)
        } label: {
            switch size {
            case .row: SetupGuideCardLabel(symbol: Self.symbol(for: origin), title: title, detail: detail)
            case .compact: SetupGuideCompactCardLabel(symbol: Self.symbol(for: origin), title: title)
            }
        }
        .buttonStyle(SetupGuideChoiceButtonStyle(isSelected: isSelected, size: size))
        .modifier(CompactCardHelp(text: size == .compact ? detail : nil))
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.primary() })
        .focused($focused, equals: origin)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("setup-guide-origin-\(Self.identifier(for: origin))")
    }

    // Only a change counts as the user's choice; the probe still decides while the default stands.
    private func select(_ origin: SetupGuideOrigin) {
        guard origin != model.origin else { return }
        model.choose(origin)
    }

    // Up and down walk the main cards, left and right the compact grid.
    private func move(_ direction: SetupGuideArrowKeys.Direction) -> Bool {
        let current = focused ?? model.origin
        let tier = Self.main.contains(current) ? Self.main : Self.compact
        let isVertical = direction == .up || direction == .down
        guard isVertical == (tier == Self.main), let index = tier.firstIndex(of: current) else { return false }
        let step = direction == .up || direction == .left ? -1 : 1
        let next = tier[min(max(index + step, 0), tier.count - 1)]
        select(next)
        focused = next
        return true
    }

    static func title(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(.otherApp): String(localized: "Import from Another App")
        case .command(.connectionsFile): String(localized: "Connections File")
        case .command(.url): String(localized: "Connection URL")
        case .command(.aws): String(localized: "AWS Account")
        case .command(.projectFolder): String(localized: "Project Folder")
        case .newConnection: String(localized: "New Connection")
        case .sample: String(localized: "Sample Database")
        }
    }

    static func detail(for origin: SetupGuideOrigin, foundApps: [String] = []) -> String {
        switch origin {
        case .command(.otherApp) where !foundApps.isEmpty:
            String(format: String(localized: "Found on this Mac: %@"), ListFormatter.localizedString(byJoining: foundApps))
        case .command(.otherApp): String(localized: "Connections and saved queries from apps on this Mac")
        case .command(.connectionsFile): String(localized: "A file exported from TablePro")
        case .command(.url): String(localized: "A connection URL you paste")
        case .command(.aws): String(localized: "Databases in your AWS account")
        case .command(.projectFolder): String(localized: "Settings found in a project's files")
        case .newConnection: String(localized: "Enter the details of your own database")
        case .sample: String(localized: "A small music store database in SQLite")
        }
    }

    static func symbol(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(.otherApp): "square.and.arrow.down.on.square"
        case .command(.connectionsFile): "doc"
        case .command(.url): "link"
        case .command(.aws): "cloud"
        case .command(.projectFolder): "folder"
        case .newConnection: "plus.circle"
        case .sample: "cylinder.split.1x2"
        }
    }

    private static func identifier(for origin: SetupGuideOrigin) -> String {
        switch origin {
        case .command(.connectionsFile): "file"
        case .command(.url): "url"
        case .command(.otherApp): "other-app"
        case .command(.aws): "aws"
        case .command(.projectFolder): "project-folder"
        case .newConnection: "new-connection"
        case .sample: "sample"
        }
    }
}

// A compact card has no room for its detail, so it moves to the tooltip.
private struct CompactCardHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
