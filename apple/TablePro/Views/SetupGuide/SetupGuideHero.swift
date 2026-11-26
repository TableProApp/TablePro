import AppKit
import SwiftUI

internal struct SetupGuideHero: View {
    let step: SetupGuideStep
    let headingFocused: AccessibilityFocusState<Bool>.Binding

    static let stepCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
                .accessibilityHidden(true)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.stepLabel(of: step))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Text(verbatim: Self.title(of: step))
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h1)
            .accessibilityFocused(headingFocused)
            .accessibilityIdentifier("setup-guide-heading")
            Text(verbatim: Self.sentence(of: step))
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var art: some View {
        if let symbol = Self.symbol(of: step) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56, alignment: .leading)
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
        }
    }

    // Fixed numbers: a flow that skips a step shows the real index, never a renumbered one.
    static func index(of step: SetupGuideStep) -> Int {
        switch step {
        case .origin: 1
        case .import: 2
        case .firstConnection: 3
        case .options: 4
        }
    }

    static func stepLabel(of step: SetupGuideStep) -> String {
        String(format: String(localized: "Step %lld of %lld"), index(of: step), stepCount)
    }

    static func announcement(of step: SetupGuideStep) -> String {
        String(format: String(localized: "Step %1$lld of %2$lld, %3$@"), index(of: step), stepCount, title(of: step))
    }

    static func title(of step: SetupGuideStep) -> String {
        switch step {
        case .origin: String(localized: "Welcome to TablePro")
        case .import: String(localized: "Import from Other Apps")
        case .firstConnection: String(localized: "First Connection")
        case .options: String(localized: "Appearance and Keys")
        }
    }

    private static func sentence(of step: SetupGuideStep) -> String {
        switch step {
        case .origin:
            String(localized: "Bring your connections, or start with a new one.")
        case .import:
            String(localized: "Select the apps to import from. You review each one before anything is saved.")
        case .firstConnection:
            String(localized: "Choose what opens when you finish.")
        case .options:
            String(localized: "Changes apply now. You can change them later in Settings.")
        }
    }

    private static func symbol(of step: SetupGuideStep) -> String? {
        switch step {
        case .origin: nil
        case .import: "square.and.arrow.down.on.square"
        case .firstConnection: "externaldrive.connected.to.line.below"
        case .options: "slider.horizontal.3"
        }
    }
}
