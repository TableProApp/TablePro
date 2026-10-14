import AppKit
import Combine

/// Puts a plain `NSTextView` on the editor's colors while the active theme sets them. A property the
/// theme leaves alone is never written, and one it stops setting gets back the value it had before, so
/// under a default theme the view stays exactly as AppKit configured it.
@MainActor
internal final class ThemeTextViewStyle {
    internal struct Natives {
        internal var background: NSColor
        internal var text: NSColor
        internal var insertionPoint: NSColor
        internal var selectedTextBackground: NSColor?

        internal init(background: NSColor, text: NSColor, insertionPoint: NSColor, selectedTextBackground: NSColor?) {
            self.background = background
            self.text = text
            self.insertionPoint = insertionPoint
            self.selectedTextBackground = selectedTextBackground
        }

        @MainActor
        internal init(of textView: NSTextView) {
            background = textView.backgroundColor
            text = textView.textColor ?? .textColor
            insertionPoint = textView.insertionPointColor ?? NativeThemeColors.insertionPoint
            selectedTextBackground = textView.selectedTextAttributes[.backgroundColor] as? NSColor
        }
    }

    private enum Property: CaseIterable {
        case background
        case text
        case insertionPoint
        case selection

        var slot: ThemeSlot {
            switch self {
            case .background: return .editorBackground
            case .text: return .editorText
            case .insertionPoint: return .editorCursor
            case .selection: return .editorSelection
            }
        }
    }

    private weak var textView: NSTextView?
    private let givenNatives: Natives?
    private var natives: Natives?
    private var themed: Set<Property> = []
    private var themeCancellable: AnyCancellable?

    /// Without `natives`, the values the text view holds when a theme first reaches it are the natives.
    internal init(textView: NSTextView, natives: Natives? = nil) {
        self.textView = textView
        givenNatives = natives
        apply()
        themeCancellable = AppEvents.shared.themeChanged
            .sink { [weak self] _ in self?.apply() }
    }

    internal func apply() {
        guard let textView else { return }
        let resolved = ThemeEngine.shared.resolved
        let wanted = Set(Property.allCases.filter { resolved.isOverridden($0.slot) })
        guard !wanted.isEmpty || !themed.isEmpty else { return }

        if themed.isEmpty {
            natives = givenNatives ?? Natives(of: textView)
        }
        guard let natives else { return }

        let palette = ThemeEngine.shared.palette
        for property in Property.allCases where wanted.contains(property) || themed.contains(property) {
            write(wanted.contains(property) ? palette[property.slot] : nil, to: property, natives: natives, of: textView)
        }
        themed = wanted
    }

    /// Hands every themed property back and stops following the theme.
    internal func detach() {
        themeCancellable = nil
        guard let textView, let natives else { return }
        for property in themed {
            write(nil, to: property, natives: natives, of: textView)
        }
        themed = []
    }

    private func write(_ color: NSColor?, to property: Property, natives: Natives, of textView: NSTextView) {
        switch property {
        case .background:
            textView.backgroundColor = color ?? natives.background
        case .text:
            textView.textColor = color ?? natives.text
        case .insertionPoint:
            textView.insertionPointColor = color ?? natives.insertionPoint
        case .selection:
            var attributes = textView.selectedTextAttributes
            attributes[.backgroundColor] = color ?? natives.selectedTextBackground
            textView.selectedTextAttributes = attributes
        }
    }
}
