//
//  EmphasisManager.swift
//  CodeEditTextView
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
    private struct EmphasisLayer: Equatable {
        let emphasis: Emphasis
        let layer: CAShapeLayer
        let textLayer: CATextLayer?

        func removeLayers() {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
            textLayer?.removeAllAnimations()
            textLayer?.removeFromSuperlayer()
        }
    }

    private var emphasisGroups: [String: [EmphasisLayer]] = [:]
    private let activeColor: NSColor = .findHighlightColor
    private let inactiveColor: NSColor = NSColor.lightGray.withAlphaComponent(0.4)
    private var originalSelectionColor: NSColor?

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

    // MARK: - Drawing Layers

    /// Updates the positions and bounds of all emphasis layers to match the current text layout.
    public func updateLayerBackgrounds() {
        for emphasis in emphasisGroups.flatMap(\.value) {
            guard let shapePath = makeShapePath(
                forStyle: emphasis.emphasis.style,
                range: emphasis.emphasis.range
            ) else {
                continue
            }
            if #available(macOS 14.0, *) {
                emphasis.layer.path = shapePath.cgPath
            } else {
                emphasis.layer.path = shapePath.cgPathFallback
            }

            // Update bounds and position
            if let cgPath = emphasis.layer.path {
                let boundingBox = cgPath.boundingBox
                emphasis.layer.bounds = boundingBox
                emphasis.layer.position = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
            }

            // Update text layer if it exists
            if let textLayer = emphasis.textLayer {
                var bounds = shapePath.bounds
                bounds.origin.y += 1 // Move down by 1 pixel
                textLayer.frame = bounds
            }
        }
    }

    private func createEmphasisLayer(for emphasis: Emphasis) -> EmphasisLayer {
        guard let shapePath = makeShapePath(forStyle: emphasis.style, range: emphasis.range) else {
            return EmphasisLayer(emphasis: emphasis, layer: CAShapeLayer(), textLayer: nil)
        }

        let layer = createShapeLayer(shapePath: shapePath, emphasis: emphasis)
        textView?.layer?.insertSublayer(layer, at: 1)

        let textLayer = createTextLayer(for: emphasis)
        if let textLayer = textLayer {
            textView?.layer?.addSublayer(textLayer)
        }

        if emphasis.inactive == false && emphasis.style == .standard {
            applyPopAnimation(to: layer)
        }

        return EmphasisLayer(emphasis: emphasis, layer: layer, textLayer: textLayer)
    }

    private func makeShapePath(forStyle emphasisStyle: EmphasisStyle, range: NSRange) -> NSBezierPath? {
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
            return path
        }
    }

    private func createShapeLayer(shapePath: NSBezierPath, emphasis: Emphasis) -> CAShapeLayer {
        let layer = CAShapeLayer()

        switch emphasis.style {
        case .standard:
            layer.cornerRadius = 4.0
            layer.fillColor = (emphasis.inactive ? inactiveColor : activeColor).cgColor
            layer.shadowColor = .black
            layer.shadowOpacity = emphasis.inactive ? 0.0 : 0.5
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            layer.shadowRadius = 1.5
            layer.opacity = 1.0
            layer.zPosition = emphasis.inactive ? 0 : 1
        case .underline(let color):
            layer.lineWidth = 1.0
            layer.lineCap = .round
            layer.strokeColor = color.cgColor
            layer.fillColor = nil
            layer.opacity = emphasis.flash ? 0.0 : 1.0
            layer.zPosition = 1
        case let .outline(color, shouldFill):
            layer.cornerRadius = 2.5
            layer.borderColor = color.cgColor
            layer.borderWidth = 0.5
            layer.fillColor = shouldFill ? color.cgColor : nil
            layer.opacity = emphasis.flash ? 0.0 : 1.0
            layer.zPosition = 1
        }

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

        return layer
    }

    private func createTextLayer(for emphasis: Emphasis) -> CATextLayer? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let shapePath = layoutManager.roundedPathForRange(emphasis.range),
              let originalString = textView.textStorage?.attributedSubstring(from: emphasis.range) else {
            return nil
        }

        var bounds = shapePath.bounds
        bounds.origin.y += 1 // Move down by 1 pixel

        // Create text layer
        let textLayer = CATextLayer()
        textLayer.frame = bounds
        textLayer.backgroundColor = NSColor.clear.cgColor
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
        let text = NSMutableAttributedString(attributedString: originalString)
        text.addAttribute(
            .foregroundColor,
            value: emphasis.inactive ? getInactiveTextColor() : NSColor.black,
            range: NSRange(location: 0, length: text.length)
        )
        textLayer.string = text
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
