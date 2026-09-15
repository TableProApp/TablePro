//
//  EmphasisManager.swift
//  TableProTextEngine
//
//  Created by Tom Ludwig on 05.11.24.
//

import AppKit

/// Manages text emphases within a text view, supporting multiple styles and groups.
///
/// Text emphasis draws attention to a range of text, indicating importance.
/// This object may be used in a code editor to emphasize search results, or indicate 
/// bracket pairs, for instance.
///
/// This object is designed to allow for easy grouping of emphasis types. An outside 
/// object is responsible for managing what emphases are visible. Because it's very 
/// likely that more than one type of emphasis may occur on the document at the same
/// time, grouping allows each emphasis to be managed separately from the others by
/// each outside object without knowledge of the other's state.
public final class EmphasisManager {
    /// Internal representation of a emphasis layer with its associated text layer
    private final class EmphasisLayer: Equatable {
        let emphasis: Emphasis
        let layer: CAShapeLayer
        private(set) var textLayer: CATextLayer?

        /// Set while the layer's geometry may not match the current text layout.
        ///
        /// Starts set: a layer has no geometry until something measures its text.
        var needsGeometryUpdate = true

        /// The vertical span the layer was last drawn over, `nil` while it draws nothing.
        var drawnYSpan: ClosedRange<CGFloat>?

        init(emphasis: Emphasis, layer: CAShapeLayer) {
            self.emphasis = emphasis
            self.layer = layer
        }

        var isAttached: Bool {
            layer.superlayer != nil
        }

        func attach(to hostLayer: CALayer, textLayer: CATextLayer?) {
            hostLayer.insertSublayer(layer, at: 1)
            guard let textLayer else { return }
            hostLayer.addSublayer(textLayer)
            self.textLayer = textLayer
        }

        func removeLayers() {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
            textLayer?.removeAllAnimations()
            textLayer?.removeFromSuperlayer()
        }

        static func == (lhs: EmphasisLayer, rhs: EmphasisLayer) -> Bool {
            lhs === rhs
        }
    }

    private var emphasisGroups: [String: [EmphasisLayer]] = [:]
    private let activeColor: NSColor = .findHighlightColor
    private let inactiveColor = NSColor.lightGray.withAlphaComponent(0.4)
    private var originalSelectionColor: NSColor?
    private var hasPendingGeometryUpdates = false
    let toolTips = EmphasisToolTips()

#if DEBUG
    /// Counts the emphases whose geometry has been measured, so a test can prove a pass that laid out nothing new
    /// measured nothing.
    var geometryUpdateCount = 0
#endif

    weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: - Add, Update, Remove

    /// Adds a single emphasis to the specified group.
    /// - Parameters:
    ///   - emphasis: The emphasis to add
    ///   - id: A group identifier
    public func addEmphasis(_ emphasis: Emphasis, for id: String) {
        addEmphases([emphasis], for: id)
    }

    /// Adds multiple emphases to the specified group.
    /// - Parameters:
    ///   - emphases: The emphases to add
    ///   - id: The group identifier
    public func addEmphases(_ emphases: [Emphasis], for id: String) {
        // Store the current selection background color if not already stored
        if originalSelectionColor == nil {
            originalSelectionColor = textView?.selectionManager.selectionBackgroundColor ?? .selectedTextBackgroundColor
        }

        let layers = emphases.map { createEmphasisLayer(for: $0) }
        emphasisGroups[id, default: []].append(contentsOf: layers)
        // Handle selections
        handleSelections(for: emphases)

        // Handle flash animations
        for flashingLayer in emphasisGroups[id, default: []].filter({ $0.emphasis.flash }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.applyFadeOutAnimation(to: flashingLayer.layer, textLayer: flashingLayer.textLayer) {
                    // Remove the emphasis from the group if it still exists
                    guard let emphasisIdx = self.emphasisGroups[id, default: []].firstIndex(
                        where: { $0 == flashingLayer }
                    ) else {
                        return
                    }

                    self.toolTips.unregister(flashingLayer.layer, in: self.textView)
                    self.emphasisGroups[id, default: []][emphasisIdx].removeLayers()
                    self.emphasisGroups[id, default: []].remove(at: emphasisIdx)

                    if self.emphasisGroups[id, default: []].isEmpty {
                        self.emphasisGroups.removeValue(forKey: id)
                    }
                }
            }
        }
    }

    /// Replaces all emphases in the specified group.
    /// - Parameters:
    ///   - emphases: The new emphases
    ///   - id: The group identifier
    public func replaceEmphases(_ emphases: [Emphasis], for id: String) {
        removeEmphases(for: id)
        addEmphases(emphases, for: id)
    }

    /// Updates the emphases for a group by transforming the existing array.
    /// - Parameters:
    ///   - id: The group identifier
    ///   - transform: The transformation to apply to the existing emphases
    public func updateEmphases(for id: String, _ transform: ([Emphasis]) -> [Emphasis]) {
        let existingEmphases = emphasisGroups[id, default: []].map { $0.emphasis }
        let newEmphases = transform(existingEmphases)
        replaceEmphases(newEmphases, for: id)
    }

    /// Removes all emphases for the given group.
    /// - Parameter id: The group identifier
    public func removeEmphases(for id: String) {
        emphasisGroups[id]?.forEach { emphasis in
            toolTips.unregister(emphasis.layer, in: textView)
            emphasis.removeLayers()
        }
        emphasisGroups[id] = nil

        textView?.layer?.layoutIfNeeded()
    }

    /// Removes all emphases for all groups.
    public func removeAllEmphases() {
        emphasisGroups.keys.forEach { removeEmphases(for: $0) }
        emphasisGroups.removeAll()

        // Restore original selection emphasizing
        if let originalColor = originalSelectionColor {
            textView?.selectionManager.selectionBackgroundColor = originalColor
        }
        originalSelectionColor = nil
    }

    /// Gets all emphases for a given group.
    /// - Parameter id: The group identifier
    /// - Returns: Array of emphases in the group
    public func getEmphases(for id: String) -> [Emphasis] {
        emphasisGroups[id, default: []].map(\.emphasis)
    }

    /// The tool tip an emphasis presents at a point in the text view, or `nil` where none is registered.
    ///
    /// Emphases own their tool tips, and AppKit only ever asks the owner. This is how anything outside the
    /// manager reads what the editor would actually show under the pointer.
    public func toolTip(at point: CGPoint) -> String? {
        guard let textView else { return nil }
        let text = toolTips.view(textView, stringForToolTip: 0, point: point, userData: nil)
        return text.isEmpty ? nil : text
    }

    private func registerToolTip(for emphasisLayer: EmphasisLayer) {
        guard emphasisLayer.emphasis.toolTip != nil, emphasisLayer.isAttached else { return }
        toolTips.register(
            emphasisLayer.emphasis.toolTip,
            rects: toolTipRects(for: emphasisLayer.emphasis.range),
            for: emphasisLayer.layer,
            in: textView
        )
    }

    private func toolTipRects(for range: NSRange) -> [CGRect] {
        guard let textView,
              range.resolved(inDocumentOfLength: textView.textStorage.length) == range else {
            return []
        }
        return textView.layoutManager.rectsFor(range: range)
    }

    // MARK: - Drawing Layers

    /// Updates the positions and bounds of all emphasis layers to match the current text layout.
    ///
    /// Layout reports what it moved through ``layoutDidUpdate(_:)``, and that is what ordinarily keeps these layers
    /// over their text. This measures every emphasis whether its text moved or not, for a caller that has changed
    /// the layout behind the layout manager's back.
    public func updateLayerBackgrounds() {
        withoutImplicitAnimations {
            var pendingRemains = false
            forEachEmphasisLayer { emphasisLayer in
                updateGeometry(of: emphasisLayer)
                pendingRemains = pendingRemains || emphasisLayer.needsGeometryUpdate
            }
            hasPendingGeometryUpdates = pendingRemains
        }
    }

    /// Brings the emphasis layers a layout pass moved back over their text.
    ///
    /// Only the emphases the pass changed are measured, and only once the lines they mark have been laid out. Every
    /// other emphasis costs one flag check, which is what keeps a document full of search matches from measuring all
    /// of them on every frame of a scroll.
    /// - Parameter update: What the layout pass laid out and what it moved.
    func layoutDidUpdate(_ update: TextLayoutUpdate) {
        if let invalidatedRange = update.invalidatedRange {
            markNeedsGeometryUpdate(in: invalidatedRange)
        }
        guard hasPendingGeometryUpdates else { return }

        withoutImplicitAnimations {
            var pendingRemains = false
            forEachEmphasisLayer { emphasisLayer in
                guard emphasisLayer.needsGeometryUpdate else { return }
                guard isLaidOut(emphasisLayer, in: update) else {
                    pendingRemains = true
                    return
                }
                updateGeometry(of: emphasisLayer)
                pendingRemains = pendingRemains || emphasisLayer.needsGeometryUpdate
            }
            hasPendingGeometryUpdates = pendingRemains
        }
    }

    private func markNeedsGeometryUpdate(in range: NSRange) {
        forEachEmphasisLayer { emphasisLayer in
            guard emphasisLayer.emphasis.range.overlaps(range) else { return }
            emphasisLayer.needsGeometryUpdate = true
            hasPendingGeometryUpdates = true
        }
    }

    /// Whether this pass laid out enough of the document to measure the emphasis.
    ///
    /// The layer's own drawn span counts as well as the range of its text. An emphasis whose text the pass has
    /// pushed out of the span it laid out leaves its layer behind, over whatever has moved in under it, so a layer
    /// standing inside the span is measured again even when its text no longer is.
    private func isLaidOut(_ emphasisLayer: EmphasisLayer, in update: TextLayoutUpdate) -> Bool {
        if let laidOutRange = update.laidOutRange, emphasisLayer.emphasis.range.overlaps(laidOutRange) {
            return true
        }
        guard let drawnYSpan = emphasisLayer.drawnYSpan else { return false }
        return drawnYSpan.overlaps(update.laidOutYSpan)
    }

    private func forEachEmphasisLayer(_ body: (EmphasisLayer) -> Void) {
        for group in emphasisGroups.values {
            for emphasisLayer in group {
                body(emphasisLayer)
            }
        }
    }

    /// Runs `body` with Core Animation's implicit actions off.
    ///
    /// These layers are sublayers of the text view's own layer rather than a view's backing layer, so Core Animation
    /// hands them an action for a bounds or position change made outside a drawing pass. A highlight marks text, and
    /// has to arrive where that text is rather than slide there.
    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Measures the emphasis against the current text layout and moves its layers there.
    /// - Parameter emphasisLayer: The emphasis to measure.
    /// - Returns: Whether the emphasis was given geometry and attached to the text view.
    @discardableResult
    private func updateGeometry(of emphasisLayer: EmphasisLayer) -> Bool {
#if DEBUG
        geometryUpdateCount += 1
#endif
        guard let shapePath = makeShapePath(
            forStyle: emphasisLayer.emphasis.style,
            range: emphasisLayer.emphasis.range
        ) else {
            // An emphasis marks specific text. Once that text is gone there is no shape to
            // draw, and the layer would otherwise keep painting the last one it had, over
            // whatever now occupies that place. Hiding rather than clearing is what lets the
            // shape come back when the range lays out again.
            emphasisLayer.layer.isHidden = true
            emphasisLayer.textLayer?.isHidden = true
            emphasisLayer.drawnYSpan = nil
            toolTips.unregister(emphasisLayer.layer, in: textView)
            emphasisLayer.needsGeometryUpdate = rangeIsInDocument(emphasisLayer.emphasis.range)
            return false
        }

        emphasisLayer.layer.isHidden = false
        emphasisLayer.textLayer?.isHidden = false
        draw(shapePath, on: emphasisLayer.layer)
        if !emphasisLayer.isAttached {
            attach(emphasisLayer)
        }

        // Update text layer if it exists
        if let textLayer = emphasisLayer.textLayer, var bounds = shapePath.drawableBounds {
            bounds.origin.y += 1 // Move down by 1 pixel
            textLayer.frame = bounds
        }
        registerToolTip(for: emphasisLayer)

        emphasisLayer.drawnYSpan = shapePath.drawableBounds.map { $0.minY...Swift.max($0.minY, $0.maxY) }
        emphasisLayer.needsGeometryUpdate = !emphasisLayer.isAttached
        return emphasisLayer.isAttached
    }

    /// Whether the range still names text that is in the document.
    ///
    /// An emphasis an edit has taken out of the document has nothing left to draw and nothing to wait for; only
    /// another edit could bring its text back, and that marks it again. One whose text is still there but that has
    /// no shape yet is waiting on its lines to be laid out, and stays marked for that.
    private func rangeIsInDocument(_ range: NSRange) -> Bool {
        guard let documentLength = textView?.textStorage.length else { return false }
        return range.resolved(inDocumentOfLength: documentLength) == range
    }

    private func createEmphasisLayer(for emphasis: Emphasis) -> EmphasisLayer {
        let emphasisLayer = EmphasisLayer(emphasis: emphasis, layer: createShapeLayer(for: emphasis))
        guard updateGeometry(of: emphasisLayer) else {
            hasPendingGeometryUpdates = hasPendingGeometryUpdates || emphasisLayer.needsGeometryUpdate
            return emphasisLayer
        }

        if emphasis.inactive == false && emphasis.style == .standard {
            applyPopAnimation(to: emphasisLayer.layer)
        }

        return emphasisLayer
    }

    private func attach(_ emphasisLayer: EmphasisLayer) {
        guard let hostLayer = textView?.layer else { return }
        emphasisLayer.attach(to: hostLayer, textLayer: createTextLayer(for: emphasisLayer.emphasis))
    }

    private func draw(_ shapePath: NSBezierPath, on layer: CAShapeLayer) {
        if #available(macOS 14.0, *) {
            layer.path = shapePath.cgPath
        } else {
            layer.path = shapePath.cgPathFallback
        }

        // Set bounds of the layer; needed for the scale animation
        if let cgPath = layer.path {
            let boundingBox = cgPath.boundingBox
            layer.bounds = boundingBox
            layer.position = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        }
    }

    private func makeShapePath(forStyle emphasisStyle: EmphasisStyle, range: NSRange) -> NSBezierPath? {
        // A range that no longer fits the document names text an edit has removed. Drawing it
        // anyway puts the emphasis somewhere it does not belong: `roundedPathForRange` answers a
        // range past the end with the caret rect at the end of the document, so a stale search
        // highlight would reappear there rather than disappear.
        guard rangeIsInDocument(range) else { return nil }

        switch emphasisStyle {
        case .standard, .outline:
            return textView?.layoutManager.roundedPathForRange(range, cornerRadius: emphasisStyle.shapeRadius)
        case .underline:
            guard let layoutManager = textView?.layoutManager else {
                return nil
            }
            let lineHeight = layoutManager.estimateLineHeight()
            let lineBottomPadding = (lineHeight - (lineHeight / layoutManager.lineHeightMultiplier)) / 4
            let path = NSBezierPath()
            for rect in layoutManager.rectsFor(range: range) {
                path.move(to: NSPoint(x: rect.minX, y: rect.maxY - lineBottomPadding))
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - lineBottomPadding))
            }
            return path.isEmpty ? nil : path
        }
    }

    private func createShapeLayer(for emphasis: Emphasis) -> CAShapeLayer {
        let layer = CAShapeLayer()

        switch emphasis.style {
        case .standard:
            layer.cornerRadius = 4.0
            layer.fillColor = (emphasis.inactive ? inactiveColor : activeColor).safeCGColor
            layer.shadowColor = .black
            layer.shadowOpacity = emphasis.inactive ? 0.0 : 0.5
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            layer.shadowRadius = 1.5
            layer.opacity = 1.0
            layer.zPosition = emphasis.inactive ? 0 : 1
        case .underline(let color):
            layer.lineWidth = 1.0
            layer.lineCap = .round
            layer.strokeColor = color.safeCGColor
            layer.fillColor = nil
            layer.opacity = emphasis.flash ? 0.0 : 1.0
            layer.zPosition = 1
        case let .outline(color, shouldFill):
            layer.cornerRadius = 2.5
            layer.borderColor = color.safeCGColor
            layer.borderWidth = 0.5
            layer.fillColor = shouldFill ? color.safeCGColor : nil
            layer.opacity = emphasis.flash ? 0.0 : 1.0
            layer.zPosition = 1
        }

        return layer
    }

    private func createTextLayer(for emphasis: Emphasis) -> CATextLayer? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage,
              emphasis.range.length > 0,
              emphasis.range.upperBound <= textStorage.length,
              let shapePath = layoutManager.roundedPathForRange(emphasis.range),
              var bounds = shapePath.drawableBounds else {
            return nil
        }

        let originalString = textStorage.attributedSubstring(from: emphasis.range)
        bounds.origin.y += 1 // Move down by 1 pixel

        // Create text layer
        let textLayer = CATextLayer()
        textLayer.frame = bounds
        textLayer.backgroundColor = NSColor.clear.safeCGColor
        textLayer.contentsScale = textView.window?.screen?.backingScaleFactor ?? 2.0
        textLayer.allowsFontSubpixelQuantization = true
        textLayer.zPosition = 2

        // Get the font from the attributed string
        if let font = originalString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            textLayer.font = font
        } else {
            textLayer.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }

        updateTextLayer(textLayer, with: originalString, emphasis: emphasis)
        return textLayer
    }

    private func updateTextLayer(
        _ textLayer: CATextLayer,
        with originalString: NSAttributedString,
        emphasis: Emphasis
    ) {
        let textColor = emphasis.inactive ? getInactiveTextColor() : NSColor.black
        let text = NSMutableAttributedString(attributedString: originalString)
        text.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: text.length))
        let display = SpecialCharacterDisplay.make(from: text, style: textView?.layoutManager.specialCharacterStyle)
        textLayer.string = display.string
        addSpecialCharacterLayers(for: display, color: textColor, to: textLayer)
    }

    private func addSpecialCharacterLayers(
        for display: SpecialCharacterDisplay,
        color: NSColor,
        to textLayer: CATextLayer
    ) {
        let marks = SpecialCharacterGeometry.positioned(
            display.marks,
            in: CTLineCreateWithAttributedString(display.string)
        )
        guard !marks.isEmpty else { return }
        let layer = SpecialCharacterMarksLayer(marks: marks, color: color)
        layer.frame = textLayer.bounds
        layer.contentsScale = textLayer.contentsScale
        textLayer.addSublayer(layer)
        layer.setNeedsDisplay()
    }

    private func getInactiveTextColor() -> NSColor {
        if textView?.effectiveAppearance.name == .darkAqua {
            return .white
        }
        return .black
    }

    // MARK: - Animations

    private func applyPopAnimation(to layer: CALayer) {
        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = [1.0, 1.25, 1.0]
        scaleAnimation.keyTimes = [0, 0.3, 1]
        scaleAnimation.duration = 0.1
        scaleAnimation.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]

        layer.add(scaleAnimation, forKey: "popAnimation")
    }

    private func applyFadeOutAnimation(to layer: CALayer, textLayer: CATextLayer?, completion: @escaping () -> Void) {
        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 1.0
        fadeAnimation.toValue = 0.0
        fadeAnimation.duration = 0.1
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fadeAnimation.fillMode = .forwards
        fadeAnimation.isRemovedOnCompletion = false

        layer.add(fadeAnimation, forKey: "fadeOutAnimation")

        if let textLayer = textLayer, let textFadeAnimation = fadeAnimation.copy() as? CABasicAnimation {
            textLayer.add(textFadeAnimation, forKey: "fadeOutAnimation")
            textLayer.add(textFadeAnimation, forKey: "fadeOutAnimation")
        }

        // Remove both layers after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAnimation.duration) {
            layer.removeFromSuperlayer()
            textLayer?.removeFromSuperlayer()
            completion()
        }
    }

    /// Handles selection of text ranges for emphases where select is true
    private func handleSelections(for emphases: [Emphasis]) {
        let selectableRanges = emphases.filter(\.selectInDocument).map(\.range)
        guard let textView, !selectableRanges.isEmpty else { return }

        textView.selectionManager.setSelectedRanges(selectableRanges)
        textView.scrollSelectionToVisible()
        textView.needsDisplay = true
    }
}
