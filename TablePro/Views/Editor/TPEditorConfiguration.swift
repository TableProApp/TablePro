import AppKit

struct TPEditorConfiguration: Equatable {
    var font: NSFont
    var theme: TPEditorTheme
    var wrapLines: Bool
    var showLineNumbers: Bool
    var showCurrentLineHighlight: Bool
    var tabWidth: Int
    var autoIndent: Bool
    var isEditable: Bool
    var contentInsets: NSEdgeInsets

    static var `default`: TPEditorConfiguration {
        TPEditorConfiguration(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            theme: .default,
            wrapLines: false,
            showLineNumbers: true,
            showCurrentLineHighlight: true,
            tabWidth: 4,
            autoIndent: true,
            isEditable: true,
            contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        )
    }

    // NSEdgeInsets does not conform to Equatable
    static func == (lhs: TPEditorConfiguration, rhs: TPEditorConfiguration) -> Bool {
        lhs.font == rhs.font
            && lhs.theme == rhs.theme
            && lhs.wrapLines == rhs.wrapLines
            && lhs.showLineNumbers == rhs.showLineNumbers
            && lhs.showCurrentLineHighlight == rhs.showCurrentLineHighlight
            && lhs.tabWidth == rhs.tabWidth
            && lhs.autoIndent == rhs.autoIndent
            && lhs.isEditable == rhs.isEditable
            && lhs.contentInsets.top == rhs.contentInsets.top
            && lhs.contentInsets.left == rhs.contentInsets.left
            && lhs.contentInsets.bottom == rhs.contentInsets.bottom
            && lhs.contentInsets.right == rhs.contentInsets.right
    }
}
