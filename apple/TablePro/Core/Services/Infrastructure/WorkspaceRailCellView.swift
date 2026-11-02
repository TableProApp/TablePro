//
//  WorkspaceRailCellView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

// AppKit because the rail is an `NSTableView`. The tile is `ConnectionTile`'s twin, so a connection looks the
// same in every list; the status mark is its own view so the label stays plain text for type select and tests.
@MainActor
internal final class WorkspaceRailCellView: NSTableCellView {
    internal static let reuseIdentifier = NSUserInterfaceItemIdentifier("WorkspaceRailCell")

    private let tile = ConnectionTileView()
    private let label = WorkspaceRailCellView.makeLabel()
    private let statusMark = ConnectionStatusMarkView()
    // A symbol on the tile's corner, so a held transaction never shares a channel with the identity fill.
    private let transactionBadge = NSImageView()
    private let content = NSLayoutGuide()
    private var tileWidthConstraint: NSLayoutConstraint?
    private var tileHeightConstraint: NSLayoutConstraint?
    private var badgeWidthConstraint: NSLayoutConstraint?
    private var badgeHeightConstraint: NSLayoutConstraint?
    private var markSizeConstraint: NSLayoutConstraint?
    private var markCenterYConstraint: NSLayoutConstraint?
    private var labelCenterXConstraint: NSLayoutConstraint?
    private var labelLeadingConstraint: NSLayoutConstraint?
    private var entry: WorkspaceRailEntry?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceRailCellView does not support NSCoder init")
    }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.usesSingleLineMode = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.allowsExpansionToolTips = true
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    private func buildHierarchy() {
        identifier = Self.reuseIdentifier

        tile.translatesAutoresizingMaskIntoConstraints = false
        statusMark.translatesAutoresizingMaskIntoConstraints = false

        transactionBadge.translatesAutoresizingMaskIntoConstraints = false
        transactionBadge.imageScaling = .scaleProportionallyUpOrDown
        transactionBadge.isHidden = true

        // Hugging keeps the mark beside the name rather than at the cell's edge.
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(tile)
        addSubview(label)
        addSubview(statusMark)
        addSubview(transactionBadge)
        addLayoutGuide(content)
        // Neither outlet is set. A source list rewrites `textField` to one 13pt run on every layout pass, which
        // clipped the container line (#3244), and the tile is a view of its own that the drag image adds below.

        let width = tile.widthAnchor.constraint(equalToConstant: 24)
        let height = tile.heightAnchor.constraint(equalToConstant: 24)
        tileWidthConstraint = width
        tileHeightConstraint = height

        let badgeWidth = transactionBadge.widthAnchor.constraint(equalToConstant: Self.badgeSize(forIcon: 24))
        let badgeHeight = transactionBadge.heightAnchor.constraint(equalToConstant: Self.badgeSize(forIcon: 24))
        badgeWidthConstraint = badgeWidth
        badgeHeightConstraint = badgeHeight

        let markSize = statusMark.widthAnchor.constraint(equalToConstant: Self.markSize(forFont: 11))
        markSizeConstraint = markSize
        let markCenterY = statusMark.centerYAnchor.constraint(equalTo: label.topAnchor)
        markCenterYConstraint = markCenterY
        let labelCenterX = label.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        labelCenterXConstraint = labelCenterX
        let labelLeading = label.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 2)
        labelLeadingConstraint = labelLeading

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),

            tile.topAnchor.constraint(equalTo: content.topAnchor),
            tile.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            width,
            height,

            label.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: WorkspaceRailMetrics.iconLabelGap),
            labelLeading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -2),
            labelCenterX,
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            markSize,
            statusMark.heightAnchor.constraint(equalTo: statusMark.widthAnchor),
            statusMark.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -Self.markGap),
            markCenterY,

            badgeWidth,
            badgeHeight,
            transactionBadge.centerXAnchor.constraint(equalTo: tile.trailingAnchor),
            transactionBadge.centerYAnchor.constraint(equalTo: tile.topAnchor),
        ])
    }

    // Proportional to the tile, so it holds at every sidebar icon size: 9pt at the medium rail.
    internal static func badgeSize(forIcon iconSize: CGFloat) -> CGFloat {
        (iconSize * 0.375).rounded()
    }

    internal static func markSize(forFont fontSize: CGFloat) -> CGFloat {
        fontSize.rounded()
    }

    private static let markGap: CGFloat = 3

    internal static func secondaryFontSize(for primaryFontSize: CGFloat) -> CGFloat {
        max(10, primaryFontSize - 1)
    }

    /// Every row is as tall as a two-line entry, so the pitch the scroll geometry works in stays
    /// uniform and a connection that gains or loses its container does not move the rows below it.
    /// The label height is measured from a label built exactly like the row's, because the line
    /// heights NSTextField lays out differ from the font's metrics by up to a point, and a row
    /// declared as a sum of constants left no slack for that.
    internal static func rowHeight(for layout: WorkspaceRailMetrics.Layout) -> CGFloat {
        let label = makeLabel()
        label.attributedStringValue = labelValue(lines: ["Ag", "Ag"], layout: layout)
        return 2 * layout.padding + layout.iconSize + WorkspaceRailMetrics.iconLabelGap
            + ceil(label.intrinsicContentSize.height)
    }

    internal func configure(entry: WorkspaceRailEntry, layout: WorkspaceRailMetrics.Layout) {
        self.entry = entry
        tileWidthConstraint?.constant = layout.iconSize
        tileHeightConstraint?.constant = layout.iconSize
        tile.configure(connection: entry.connection, size: layout.iconSize)

        let badgeSize = Self.badgeSize(forIcon: layout.iconSize)
        badgeWidthConstraint?.constant = badgeSize
        badgeHeightConstraint?.constant = badgeSize
        transactionBadge.image = entry.transaction.flatMap {
            NSImage(systemSymbolName: Self.transactionSymbolName(for: $0), accessibilityDescription: nil)
        }
        transactionBadge.isHidden = entry.transaction == nil

        label.attributedStringValue = Self.labelValue(lines: Self.labelLines(for: entry), layout: layout)

        let presentation = entry.presentation
        let markSize = Self.markSize(forFont: layout.fontSize)
        markSizeConstraint?.constant = markSize
        markCenterYConstraint?.constant = Self.firstLineHeight(for: layout) / 2
        let markWidth = presentation.symbol == nil ? 0 : markSize + Self.markGap
        labelCenterXConstraint?.constant = markWidth / 2
        labelLeadingConstraint?.constant = 2 + markWidth
        applyTint()

        toolTip = Self.tooltipText(for: entry)
        setAccessibilityLabel(Self.voiceOverLabel(for: entry))
    }

    private static func firstLineHeight(for layout: WorkspaceRailMetrics.Layout) -> CGFloat {
        let font = NSFont.systemFont(ofSize: layout.fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    internal static func transactionSymbolName(for state: SessionTransactionTracker.State) -> String {
        switch state {
        case .open: ConnectionTransactionBarContent.openSymbolName
        case .aborted: ConnectionTransactionBarContent.abortedSymbolName
        }
    }

    internal static func transactionTint(for state: SessionTransactionTracker.State) -> NSColor {
        switch state {
        case .open: .systemOrange
        case .aborted: .systemRed
        }
    }

    // The icon and label outlets are empty, so both are drawn here, in the normal style as AppKit draws its own:
    // the image floats over the window, where selected-row white would vanish.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        var components = super.draggingImageComponents
        let wasEmphasized = tile.isEmphasized
        tile.isEmphasized = false
        if let icon = snapshot(of: tile, key: .icon) { components.append(icon) }
        tile.isEmphasized = wasEmphasized
        guard let cell = label.cell else { return components }
        let style = cell.backgroundStyle
        cell.backgroundStyle = .normal
        if let text = snapshot(of: label, key: .label) { components.append(text) }
        cell.backgroundStyle = style
        return components
    }

    private func snapshot(of view: NSView, key: NSDraggingItem.ImageComponentKey) -> NSDraggingImageComponent? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let component = NSDraggingImageComponent(key: key)
        component.contents = image
        component.frame = convert(view.bounds, from: view)
        return component
    }

    private static func labelValue(
        lines: [String],
        layout: WorkspaceRailMetrics.Layout
    ) -> NSAttributedString {
        guard let primary = lines.first else { return NSAttributedString() }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        let value = NSMutableAttributedString(
            string: primary,
            attributes: [
                .font: NSFont.systemFont(ofSize: layout.fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        guard lines.count == 2 else { return value }

        value.append(NSAttributedString(
            string: "\n\(lines[1])",
            attributes: [
                .font: NSFont.systemFont(ofSize: secondaryFontSize(for: layout.fontSize)),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        ))
        return value
    }

    /// Blank is the test on both halves, not empty on one of them. A container of spaces reads as
    /// absent and has to be treated as absent, or the row spends its second line drawing nothing and
    /// pushes the name it exists to show off centre.
    private static func labelLines(for entry: WorkspaceRailEntry) -> [String] {
        let connection = singleLine(entry.connection.name)
        let container = singleLine(entry.container)
        guard !connection.isBlank else { return container.isBlank ? [] : [container] }
        guard !container.isBlank else { return [connection] }
        return [connection, container]
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    // The identity fill stays lit on the selected row: it is the one thing there the selection cannot restate.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        let isEmphasized = backgroundStyle == .emphasized
        tile.isEmphasized = isEmphasized
        if let entry {
            statusMark.configure(entry.presentation, isEmphasized: isEmphasized)
        }
        transactionBadge.contentTintColor = isEmphasized
            ? nil
            : entry?.transaction.map(Self.transactionTint(for:))
    }

    internal static func tooltipText(for entry: WorkspaceRailEntry) -> String {
        let connection = entry.connection
        var parts = [connection.name, connection.type.displayName]
        if !connection.host.isEmpty {
            parts.append(connection.host)
        }
        if !entry.container.isEmpty {
            parts.append(entry.container)
        }
        if let identity = connection.identityColor {
            parts.append(String(format: String(localized: "Color: %@"), identity.displayName))
        }
        if let help = entry.presentation.help {
            parts.append(help)
        }
        if let transaction = entry.transaction {
            parts.append(transactionTooltip(for: transaction))
        }
        return parts.joined(separator: ", ")
    }

    internal static func voiceOverLabel(for entry: WorkspaceRailEntry) -> String {
        var parts = [entry.connection.name, entry.connection.type.displayName]
        if !entry.container.isEmpty {
            parts.append(String(format: containerFormat(for: entry.containerTarget), entry.container))
        }
        parts.append(entry.presentation.accessibilityStatus)
        if let transaction = entry.transaction {
            parts.append(transactionSpoken(for: transaction))
        }
        if let identity = entry.connection.identityColor {
            parts.append(String(format: String(localized: "color %@"), identity.displayName))
        }
        return parts.joined(separator: ", ")
    }

    private static func transactionTooltip(for state: SessionTransactionTracker.State) -> String {
        switch state {
        case .open: String(localized: "Transaction open")
        case .aborted: String(localized: "Transaction failed")
        }
    }

    private static func transactionSpoken(for state: SessionTransactionTracker.State) -> String {
        switch state {
        case .open: String(localized: "transaction open")
        case .aborted: String(localized: "transaction failed")
        }
    }

    private static func containerFormat(for target: ContainerSwitchTarget?) -> String {
        switch target {
        case .schema:
            return String(localized: "schema %@")
        case .database, nil:
            return String(localized: "database %@")
        }
    }
}
