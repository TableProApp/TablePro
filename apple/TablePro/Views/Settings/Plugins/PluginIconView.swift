import AppKit
import SwiftUI

struct PluginIconView: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        icon
            .frame(width: size + 4, height: size + 4)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        if PluginIconKind.isSymbol(name) {
            Image(systemName: name)
                .font(.system(size: size * 0.8))
        } else {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}

// A symbol lookup costs tens of microseconds, and every row asks on each render.
@MainActor
private enum PluginIconKind {
    private static var symbols: [String: Bool] = [:]

    static func isSymbol(_ name: String) -> Bool {
        if let known = symbols[name] { return known }
        let isSymbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbols[name] = isSymbol
        return isSymbol
    }
}
