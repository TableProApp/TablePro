//
//  TreeOutlineCellView.swift
//  TablePro
//

import AppKit

internal struct TreeOutlineFonts: Equatable {
    private static let verticalPadding: CGFloat = 10

    let value: NSFont
    let key: NSFont

    var rowHeight: CGFloat {
        let layoutManager = NSLayoutManager()
        let lineHeight = max(layoutManager.defaultLineHeight(for: value), layoutManager.defaultLineHeight(for: key))
        return ceil(lineHeight) + Self.verticalPadding
    }
}

/// One accessibility element per row, as the SwiftUI row was. The swatch is its only child.
internal final class TreeOutlineCellView: NSTableCellView, NSTextFieldDelegate {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("TreeOutlineCell")

    private static let spacing: CGFloat = 4
    private static let edgeInset: CGFloat = 2
    private static let badgeGap: CGFloat = 6
    private static let maximumKeyShare: CGFloat = 0.6
    private static let keysHandedBack: Set<Selector> = [
        #selector(NSResponder.moveUp(_:)),
        #selector(NSResponder.moveDown(_:)),
        #selector(NSResponder.moveLeft(_:)),
        #selector(NSResponder.moveRight(_:))
    ]

    internal let valueField = TreeValueField(labelWithString: "")
    internal let swatch = TreeColorSwatchView()
    internal let keyField = NSTextField(labelWithString: "")
    internal let visibilityField = NSTextField(labelWithString: "")
    internal let typeBadge = TreeBadgeView()

    private let separatorField = NSTextField(labelWithString: ":")
    private var content: TreeRowContent?
    private var valueFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    override internal init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        configureSubviews()
        installLayout()
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("TreeOutlineCellView does not support NSCoder init")
    }

    override internal var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    internal func configure(content: TreeRowContent, fonts: TreeOutlineFonts, accessibilityDescription: String) {
        self.content = content
        valueFont = fonts.value

        let hasKey = content.key != nil
        keyField.isHidden = !hasKey
        keyField.stringValue = content.key ?? ""
        keyField.font = fonts.key
        separatorField.isHidden = !hasKey
        separatorField.font = .systemFont(ofSize: fonts.value.pointSize)
        visibilityField.isHidden = !hasKey || content.visibilityBadge == nil
        visibilityField.stringValue = content.visibilityBadge ?? ""
        typeBadge.text = content.typeBadge

        if case .color(let color) = content.decoration {
            swatch.color = color.nsColor
            swatch.isHidden = false
        } else {
            swatch.isHidden = true
        }

        if case .link(let url) = content.decoration {
            valueField.linkURL = url
        } else {
            valueField.linkURL = nil
        }
        valueField.linkRange = TreeValueStyle.linkRange(in: content)
        valueField.toolTip = valueField.linkURL?.absoluteString
        /// Off for a plain value, so a partial copy puts no colored text on the clipboard.
        valueField.allowsEditingTextAttributes = valueField.linkURL != nil
        valueField.font = fonts.value
        if valueField.linkURL == nil {
            valueField.stringValue = content.value
        }

        setAccessibilityLabel(accessibilityDescription)
        setAccessibilityCustomActions(valueField.linkURL == nil ? nil : [openLinkAction])
        applyStyle()
    }

    override internal func accessibilityChildren() -> [Any]? {
        swatch.isHidden ? [] : [swatch]
    }

    /// Arrows do nothing in a read-only line, so they move the row selection. Escape ends the text
    /// selection and keeps the row selected.
    internal func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isEscape = commandSelector == #selector(NSResponder.cancelOperation(_:))
        guard isEscape || Self.keysHandedBack.contains(commandSelector),
              let outline = enclosingOutline, let window = outline.window else { return false }
        window.makeFirstResponder(outline)
        if !isEscape, let event = NSApplication.shared.currentEvent, event.type == .keyDown {
            outline.keyDown(with: event)
        }
        return true
    }

    private var enclosingOutline: NSOutlineView? {
        var ancestor = superview
        while let view = ancestor {
            if let outline = view as? NSOutlineView { return outline }
            ancestor = view.superview
        }
        return nil
    }

    private var openLinkAction: NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(
            name: String(localized: "Open Link"),
            target: self,
            selector: #selector(openLinkFromAccessibility)
        )
    }

    @objc private func openLinkFromAccessibility() -> Bool {
        guard let url = valueField.linkURL else { return false }
        DataLinkPolicy.open(url)
        return true
    }

    private func applyStyle() {
        guard let content else { return }
        let isEmphasized = backgroundStyle == .emphasized
        let selectedText = NSColor.alternateSelectedControlTextColor
        let secondary = isEmphasized ? selectedText.withAlphaComponent(0.7) : NSColor.secondaryLabelColor

        keyField.textColor = isEmphasized ? selectedText : .systemBlue
        separatorField.textColor = secondary
        visibilityField.textColor = secondary
        swatch.isOnEmphasizedRow = isEmphasized
        typeBadge.isOnEmphasizedRow = isEmphasized

        guard valueField.linkURL != nil else {
            valueField.textColor = TreeValueStyle.textColor(for: content.tone, isEmphasized: isEmphasized)
            return
        }
        valueField.attributedStringValue = TreeValueStyle.attributedValue(
            content,
            font: valueFont,
            isEmphasized: isEmphasized
        )
        /// Measured: during a text selection this replaces the field editor's attributes, link run included.
        valueField.markLinkInFieldEditor()
    }

    private func configureSubviews() {
        for field in [keyField, visibilityField, separatorField, valueField] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
        }
        valueField.isSelectable = true
        valueField.delegate = self
        visibilityField.font = .preferredFont(forTextStyle: .caption2)

        keyField.setContentHuggingPriority(.required, for: .horizontal)
        keyField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for view in [visibilityField, separatorField, swatch, typeBadge] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        valueField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func installLayout() {
        let stack = NSStackView(views: [keyField, visibilityField, separatorField, swatch, valueField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        typeBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(typeBadge)

        /// Below required, so a cell laid out at zero width breaks them quietly.
        let stackTrailing = stack.trailingAnchor.constraint(equalTo: typeBadge.leadingAnchor, constant: -Self.badgeGap)
        stackTrailing.priority = .init(999)
        let keyWidth = keyField.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: Self.maximumKeyShare)
        keyWidth.priority = .init(999)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edgeInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackTrailing,
            keyWidth,
            typeBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeInset),
            typeBadge.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
