//
//  StatusBarChrome.swift
//  TablePro
//

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
    /// False where the host paints a custom backdrop under the bar: the material does not follow a custom window color.
    @Entry var statusBarDrawsMaterial = true
}

private struct StatusBarChromeModifier: ViewModifier {
    @Environment(\.statusBarDrawsMaterial) private var drawsMaterial

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, StatusBarChrome.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: StatusBarChrome.height)
        }
        .background {
            if drawsMaterial {
                StatusBarMaterial()
            }
        }
    }
}

extension View {
    /// Fixed height, one material, one separator. Applied by every bottom bar in the app.
    func statusBarChrome() -> some View {
        modifier(StatusBarChromeModifier())
    }

    func statusBarDrawsMaterial(_ drawsMaterial: Bool) -> some View {
        environment(\.statusBarDrawsMaterial, drawsMaterial)
    }

    /// Height only: the glyph keeps its size and its width, so no control gets wider or narrower.
    func statusBarControlIcon(besideTitle: Bool) -> some View {
        frame(height: StatusBarChrome.controlIconHeight(besideTitle: besideTitle))
    }
}
