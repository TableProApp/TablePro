import AppKit

struct TPEditorTheme: Equatable {
    var background: NSColor
    var text: NSColor
    var cursor: NSColor
    var selection: NSColor
    var lineHighlight: NSColor
    var keyword: NSColor
    var string: NSColor
    var number: NSColor
    var comment: NSColor
    var type: NSColor
    var variable: NSColor
    var invisible: NSColor

    static var `default`: TPEditorTheme {
        TPEditorTheme(
            background: .textBackgroundColor,
            text: .textColor,
            cursor: .textColor,
            selection: .selectedTextBackgroundColor,
            lineHighlight: NSColor.textColor.withAlphaComponent(0.04),
            keyword: .systemPurple,
            string: .systemRed,
            number: .systemBlue,
            comment: .systemGreen,
            type: .systemTeal,
            variable: .systemOrange,
            invisible: .tertiaryLabelColor
        )
    }
}
