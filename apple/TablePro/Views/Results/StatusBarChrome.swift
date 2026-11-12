import AppKit
import SwiftUI

/// The one owner of what a bottom status bar looks like, so every bar has the same height and material.
enum StatusBarChrome {
    /// Measured off Finder's own status bar through the accessibility API.
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 10
    static let clusterSpacing: CGFloat = 8

    /// A small bordered button takes its height from its glyph (18 to 21pt), so one box keeps every control in a bar at one height.
    static func controlIconHeight(besideTitle: Bool) -> CGFloat {
        besideTitle ? 12 : 14
    }
}

/// `NSVisualEffectView` rather than a flat colour because a bar is window chrome: AppKit desaturates
/// the material when the window stops being key, and a `Color` never does.
private struct StatusBarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension EnvironmentValues {
    /// Set by the host that puts a bar above its content rather than below it. Read by the chrome
    /// and by every control in the bar that opens a popover, so the bar never changes its own
    /// contents to move.
    @Entry var statusBarPlacement: StatusBarPlacement = .bottom
}

extension StatusBarPlacement {
    /// Toward the content the bar describes, so a popover never opens over the chrome on the bar's
    /// far side: the editor, the tab strip or the toolbar.
    var popoverArrowEdge: Edge {
        switch self {
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// The rule sits between the bar and the content it borders.
    var dividerEdge: VerticalEdge {
        switch self {
        case .top: .bottom
        case .bottom: .top
        }
    }
}

// The material does not follow a custom window color, so over a themed backdrop the bar draws none.
private struct StatusBarChromeModifier: ViewModifier {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.statusBarPlacement) private var placement
    @Environment(\.isOnSplitItem) private var isOnSplitItem

    func body(content: Content) -> some View {
        let isThemed = ThemeBackdropState.isThemed(highContrast: contrast == .increased, onSplitItem: isOnSplitItem)
        return VStack(spacing: 0) {
            if placement.dividerEdge == .top {
                Divider()
            }
            content
                .padding(.horizontal, StatusBarChrome.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: StatusBarChrome.height)
            if placement.dividerEdge == .bottom {
                Divider()
            }
        }
        .background {
            if !isThemed {
                StatusBarMaterial()
            }
        }
    }
}

extension View {
    func statusBarChrome() -> some View {
        modifier(StatusBarChromeModifier())
    }

    /// Height only: the glyph keeps its size and its width, so no control gets wider or narrower.
    func statusBarControlIcon(besideTitle: Bool) -> some View {
        frame(height: StatusBarChrome.controlIconHeight(besideTitle: besideTitle))
    }
}
