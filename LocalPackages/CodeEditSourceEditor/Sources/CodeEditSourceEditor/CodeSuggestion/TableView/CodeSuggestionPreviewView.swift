//
//  CodeSuggestionPreviewView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/28/25.
//

import SwiftUI

final class CodeSuggestionPreviewView: NSVisualEffectView {
    private let spacing: CGFloat = 5

    var sourcePreview: NSAttributedString? {
        didSet {
            sourcePreviewLabel.attributedStringValue = sourcePreview ?? NSAttributedString(string: "")
            sourcePreviewLabel.isHidden = sourcePreview == nil
        }
    }

    var documentation: String? {
        didSet {
            documentationLabel.stringValue = documentation ?? ""
            documentationLabel.isHidden = documentation == nil
        }
    }

    var pathComponents: [String] = [] {
        didSet {
            configurePathComponentsLabel()
        }
    }

    var targetRange: CursorPosition? {
        didSet {
            configurePathComponentsLabel()
        }
    }

    var font: NSFont = .systemFont(ofSize: 12) {
        didSet {
            sourcePreviewLabel.font = font
            pathComponentsLabel.font = .systemFont(ofSize: font.pointSize)
        }
    }
    var documentationFont: NSFont = .systemFont(ofSize: 12) {
        didSet {
            documentationLabel.font = documentationFont
        }
    }

    var stackView: NSStackView = NSStackView()
    var dividerView: NSView = NSView()
    var sourcePreviewLabel: NSTextField = NSTextField()
    var documentationLabel: NSTextField = NSTextField()
    var pathComponentsLabel: NSTextField = NSTextField()

    init() {
        super.init(frame: .zero)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.spacing = spacing
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.setContentCompressionResistancePriority(.required, for: .vertical)
        stackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stackView)

        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(dividerView)

        self.material = .windowBackground
        self.blendingMode = .behindWindow

        styleStaticLabel(sourcePreviewLabel)
        styleStaticLabel(documentationLabel)
        styleStaticLabel(pathComponentsLabel)

        pathComponentsLabel.maximumNumberOfLines = 1
        pathComponentsLabel.lineBreakMode = .byTruncatingMiddle
        pathComponentsLabel.usesSingleLineMode = true

        stackView.addArrangedSubview(sourcePreviewLabel)
        stackView.addArrangedSubview(documentationLabel)
        stackView.addArrangedSubview(pathComponentsLabel)

        NSLayoutConstraint.activate([
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1),

            stackView.topAnchor.constraint(equalTo: dividerView.bottomAnchor, constant: spacing),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SuggestionController.WINDOW_PADDING),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func hideIfEmpty() {
        isHidden = sourcePreview == nil && documentation == nil && pathComponents.isEmpty
    }

    func setPreferredMaxLayoutWidth(width: CGFloat) {
        sourcePreviewLabel.preferredMaxLayoutWidth = width
        documentationLabel.preferredMaxLayoutWidth = width
        pathComponentsLabel.preferredMaxLayoutWidth = width
    }

    private func styleStaticLabel(_ label: NSTextField) {
        label.isEditable = false
        label.isSelectable = true
        label.allowsDefaultTighteningForTruncation = false
        label.isBezeled = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configurePathComponentsLabel() {
        pathComponentsLabel.isHidden = pathComponents.isEmpty

        let folder = NSTextAttachment()
        folder.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(paletteColors: [NSColor.systemBlue]).applying(.init(pointSize: font.pointSize, weight: .regular))
            )

        let string: NSMutableAttributedString = NSMutableAttributedString(attachment: folder)
        string.append(NSAttributedString(string: " "))

        let separator = NSTextAttachment()
        separator.image = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(paletteColors: [NSColor.labelColor])
                .applying(.init(pointSize: font.pointSize + 1, weight: .regular))
            )

        for (idx, component) in pathComponents.enumerated() {
            string.append(NSAttributedString(string: component, attributes: [.foregroundColor: NSColor.labelColor]))
            if idx != pathComponents.count - 1 {
                string.append(NSAttributedString(string: " "))
                string.append(NSAttributedString(attachment: separator))
                string.append(NSAttributedString(string: " "))
            }
        }

        if let targetRange {
            string.append(NSAttributedString(string: ":\(targetRange.start.line)"))
            if targetRange.start.column > 1 {
                string.append(NSAttributedString(string: ":\(targetRange.start.column)"))
            }
        }
        if let paragraphStyle = NSMutableParagraphStyle.default.mutableCopy() as? NSMutableParagraphStyle {
            paragraphStyle.lineBreakMode = .byTruncatingMiddle
            string.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: string.length)
            )
        }

        pathComponentsLabel.attributedStringValue = string
    }
}
