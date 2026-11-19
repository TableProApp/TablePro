//
//  EditorTabItemView.swift
//  TablePro
//

import AppKit

extension NSPasteboard.PasteboardType {
    internal static let editorTab = NSPasteboard.PasteboardType("com.TablePro.editor-tab")
}

// AppKit on purpose: a tab is a drag source, a key view and a tab button element, none of which a hosted view can be here.
@MainActor
internal final class EditorTabItemView: NSView {
    internal private(set) var item: EditorTabItem
    internal weak var strip: EditorTabStripView?

    internal var showsLeadingSeparator = false {
        didSet { if showsLeadingSeparator != oldValue { needsDisplay = true } }
    }

    internal var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateCloseButton()
            needsDisplay = true
        }
    }

    internal var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            updateCloseButton()
            updateTitle()
            needsDisplay = true
        }
    }

    internal let closeButton: NSButton
    internal let titleField = NSTextField(labelWithString: "")
    private let pinView = NSImageView()
    private let statusView = NSImageView()
    private let spinner = NSProgressIndicator()
    private var pressLocation: NSPoint?
    private var middlePressed = false

    internal init(item: EditorTabItem) {
        self.item = item
        closeButton = NSButton()
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        configureSubviews()
        apply(item)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("EditorTabItemView does not support NSCoder init")
    }

    override internal var isFlipped: Bool { true }
    override internal var mouseDownCanMoveWindow: Bool { false }

    // HIG: people expect to act on a tab in an inactive window without bringing it forward first.
    override internal func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    internal func apply(_ newItem: EditorTabItem) {
        item = newItem
        toolTip = newItem.tooltip
        pinView.isHidden = !newItem.isPinned
        updateTitle()
        updateStatus()
        updateCloseButton()
        needsDisplay = true
        needsLayout = true
    }

    private func configureSubviews() {
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        titleField.setAccessibilityElement(false)
        addSubview(titleField)

        let pinConfiguration = NSImage.SymbolConfiguration(pointSize: EditorTabStripLayout.pinGlyphSize, weight: .regular)
        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(pinConfiguration)
        pinView.contentTintColor = .secondaryLabelColor
        pinView.setAccessibilityElement(false)
        addSubview(pinView)

        statusView.setAccessibilityElement(false)
        addSubview(statusView)

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(spinner)

        let closeConfiguration = NSImage.SymbolConfiguration(
            pointSize: EditorTabStripLayout.closeGlyphSize,
            weight: .semibold
        )
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "Close Tab")
        )?.withSymbolConfiguration(closeConfiguration)
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .circular
        closeButton.controlSize = .mini
        closeButton.showsBorderOnlyWhileMouseInside = true
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = String(localized: "Close Tab")
        closeButton.setAccessibilityLabel(String(localized: "Close Tab"))
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    private func updateTitle() {
        titleField.stringValue = item.title
        titleField.font = item.isPreview ? Self.previewFont : Self.titleFont
        titleField.textColor = titleColor
        pinView.contentTintColor = titleColor
    }

    private var titleColor: NSColor {
        guard isWindowActive else {
            return item.isSelected ? .secondaryLabelColor : .tertiaryLabelColor
        }
        return item.isSelected ? .labelColor : .secondaryLabelColor
    }

    private func updateStatus() {
        switch item.status {
        case .idle:
            statusView.isHidden = true
            spinner.stopAnimation(nil)
        case .running:
            statusView.isHidden = true
            spinner.startAnimation(nil)
        case .finished:
            spinner.stopAnimation(nil)
            showStatus(symbol: "checkmark.circle.fill", color: .controlAccentColor)
        case .failed:
            spinner.stopAnimation(nil)
            showStatus(symbol: "exclamationmark.triangle.fill", color: .systemRed)
        }
    }

    private func showStatus(symbol: String, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: EditorTabStripLayout.statusGlyphSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        statusView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        statusView.isHidden = false
    }

    // The system bar shows the close button only under the pointer, on the selected tab too.
    private func updateCloseButton() {
        closeButton.isHidden = !(isHovered && isWindowActive) || bounds.width < EditorTabStripLayout.minimumContentWidth
    }

    override internal func layout() {
        super.layout()
        let metrics = EditorTabStripLayout.self
        let hasRoom = bounds.width >= metrics.minimumContentWidth
        titleField.isHidden = !hasRoom
        pinView.isHidden = !hasRoom || !item.isPinned
        spinner.isHidden = !hasRoom
        statusView.isHidden = !hasRoom || item.status == .idle || item.status == .running
        updateCloseButton()
        guard hasRoom else { return }

        let slot = metrics.accessoryWidth
        let midY = bounds.midY
        closeButton.frame = CGRect(x: metrics.accessoryInset, y: midY - slot / 2, width: slot, height: slot)
        let statusFrame = CGRect(
            x: bounds.maxX - metrics.accessoryInset - slot,
            y: midY - slot / 2,
            width: slot,
            height: slot
        )
        statusView.frame = statusFrame
        spinner.frame = statusFrame

        let inset = metrics.accessoryInset + slot + metrics.pinSpacing
        let available = max(bounds.width - inset * 2, 0)
        let pinWidth = item.isPinned ? metrics.pinGlyphSize + metrics.pinSpacing : 0
        let textSize = titleField.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height))
        let textWidth = min(ceil(textSize.width), max(available - pinWidth, 0))
        let textHeight = ceil(textSize.height)
        let startX = bounds.midX - (pinWidth + textWidth) / 2
        pinView.frame = CGRect(
            x: startX,
            y: midY - metrics.pinGlyphSize / 2,
            width: metrics.pinGlyphSize,
            height: metrics.pinGlyphSize
        )
        titleField.frame = CGRect(x: startX + pinWidth, y: midY - textHeight / 2, width: textWidth, height: textHeight)
    }

    override internal func draw(_ dirtyRect: NSRect) {
        let metrics = EditorTabStripLayout.self
        if showsLeadingSeparator {
            EditorTabStripPalette.separatorColor.setFill()
            NSRect(
                x: 0,
                y: bounds.midY - metrics.separatorHeight / 2,
                width: metrics.separatorWidth,
                height: metrics.separatorHeight
            ).fill()
        }
        if item.isSelected {
            EditorTabStripPalette.selectedColor.setFill()
            capsule(in: bounds).fill()
            EditorTabStripPalette.selectionEdgeColor.setStroke()
            let edge = capsule(in: bounds.insetBy(dx: metrics.hairline / 2, dy: metrics.hairline / 2))
            edge.lineWidth = metrics.hairline
            edge.stroke()
        } else if isHovered, isWindowActive {
            EditorTabStripPalette.hoverColor.setFill()
            capsule(in: bounds).fill()
        }
    }

    private func capsule(in rect: NSRect) -> NSBezierPath {
        let radius = rect.height / 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    internal func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: bitmap)
        image.addRepresentation(bitmap)
        return image
    }

    @objc
    private func closeClicked() {
        strip?.commands?.close(item.id)
    }

    // MARK: - Pointer

    override internal func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    override internal func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        strip?.activate(item.id, click: EditorTabClick(event: event))
    }

    override internal func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= EditorTabStripLayout.dragThreshold else { return }
        pressLocation = nil
        strip?.beginDrag(of: self, with: event)
    }

    override internal func mouseUp(with event: NSEvent) {
        pressLocation = nil
    }

    override internal func otherMouseDown(with event: NSEvent) {
        guard event.isMiddleButton else {
            super.otherMouseDown(with: event)
            return
        }
        middlePressed = true
    }

    override internal func otherMouseUp(with event: NSEvent) {
        guard event.isMiddleButton, middlePressed else {
            super.otherMouseUp(with: event)
            return
        }
        endMiddleClick(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    internal func beginMiddleClick() {
        middlePressed = true
    }

    // AppKit sends the release to the view that took the press, wherever the pointer went.
    internal func endMiddleClick(atViewPoint point: NSPoint) {
        guard middlePressed else { return }
        middlePressed = false
        guard bounds.contains(point) else { return }
        strip?.commands?.close(item.id)
    }

    override internal func menu(for event: NSEvent) -> NSMenu? {
        guard let commands = strip?.commands else { return nil }
        return EditorTabContextMenuBuilder.menu(for: item.id, commands: commands)
    }

    // MARK: - Keyboard

    override internal var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override internal var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override internal var focusRingMaskBounds: NSRect { bounds }

    override internal func drawFocusRingMask() {
        capsule(in: bounds).fill()
    }

    override internal func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow:
            strip?.moveFocus(from: self, by: -1)
        case .rightArrow:
            strip?.moveFocus(from: self, by: 1)
        case .carriageReturn, .enter:
            strip?.commands?.activate(item.id)
        default:
            guard event.charactersIgnoringModifiers == " " else {
                super.keyDown(with: event)
                return
            }
            strip?.commands?.activate(item.id)
        }
    }

    // MARK: - Accessibility

    override internal func isAccessibilityElement() -> Bool { true }
    override internal func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override internal func accessibilitySubrole() -> NSAccessibility.Subrole? { .tabButtonSubrole }
    override internal func accessibilityLabel() -> String? { item.title }
    override internal func accessibilityIdentifier() -> String { "editor-tab" }
    override internal func accessibilityValue() -> Any? { NSNumber(value: item.isSelected) }
    override internal func accessibilityValueDescription() -> String? { item.accessibilityDescription }
    override internal func isAccessibilitySelected() -> Bool { item.isSelected }

    override internal func accessibilityPerformPress() -> Bool {
        strip?.commands?.activate(item.id)
        return strip?.commands != nil
    }

    override internal func accessibilityPerformShowMenu() -> Bool {
        guard let commands = strip?.commands else { return false }
        let menu = EditorTabContextMenuBuilder.menu(for: item.id, commands: commands)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: self)
        return true
    }

    override internal func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let commands = strip?.commands else { return nil }
        return EditorTabContextMenuBuilder.accessibilityActions(for: item.id, commands: commands)
    }

    private static let titleFont = NSFont.systemFont(ofSize: EditorTabStripLayout.fontSize)
    private static let previewFont = NSFontManager.shared.convert(titleFont, toHaveTrait: .italicFontMask)
}

extension EditorTabItemView: NSDraggingSource {
    internal func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    internal func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    internal func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        strip?.dragDidEnd(of: self, at: screenPoint, operation: operation)
    }
}
