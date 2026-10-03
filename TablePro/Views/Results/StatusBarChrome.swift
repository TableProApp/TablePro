//
//  StatusBarChrome.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The one owner of what a bottom status bar looks like.
///
/// Both of the app's status bars used to paint themselves: the result bar with
/// `controlBackgroundColor`, which is the same colour as the data grid above it so the bar did not
/// read as a separate surface, and the inspector bar with `windowBackgroundColor`. Routing both
/// through here also fixes the height, which used to float with whatever the bar happened to contain.
enum StatusBarChrome {
    /// Measured off Finder's own status bar through the accessibility API.
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 10
    static let clusterSpacing: CGFloat = 8

    /// The layout height a control's glyph is given. A small bordered button takes its height from
    /// its glyph, measured at 18pt for `eye`, 19pt for the circled filter and 20pt for `eye.slash`
    /// when the glyph stands alone, and 20 or 21pt beside a title, so the controls in one bar stood
    /// at three heights. One box makes each the height of a text-only control: 12pt beside a title,
    /// whose own line sets the height, and 14pt alone.
    static func controlIconHeight(besideTitle: Bool) -> CGFloat {
        besideTitle ? 12 : 14
    }
}

struct StatusBarSeparator: View {
    var body: some View {
        Text(verbatim: "·")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
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

private struct StatusBarChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, StatusBarChrome.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: StatusBarChrome.height)
        }
        .background(StatusBarMaterial())
    }
}

extension View {
    /// Fixed height, one material, one separator. Applied by every bottom bar in the app.
    func statusBarChrome() -> some View {
        modifier(StatusBarChromeModifier())
    }

    /// Height only: the glyph keeps its size and its width, so no control gets wider or narrower.
    func statusBarControlIcon(besideTitle: Bool) -> some View {
        frame(height: StatusBarChrome.controlIconHeight(besideTitle: besideTitle))
    }
}
