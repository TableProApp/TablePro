//
//  SpecialCharacterStyle.swift
//  CodeEditTextView
//

import AppKit

public struct SpecialCharacterStyle: Equatable {
    public var color: NSColor
    public var maximumMarksPerLine: Int

    public init(color: NSColor = .systemOrange, maximumMarksPerLine: Int = 4_096) {
        self.color = color
        self.maximumMarksPerLine = maximumMarksPerLine
    }
}

public struct SpecialCharacterMark: Equatable {
    public let offset: Int
    public let length: Int
    public let character: SpecialCharacter
    public let font: NSFont
    public let color: NSColor
    public internal(set) var minX: CGFloat = 0
    public internal(set) var maxX: CGFloat = 0

    func offset(by delta: Int) -> SpecialCharacterMark {
        SpecialCharacterMark(offset: offset + delta, length: length, character: character, font: font, color: color)
    }
}

public struct TextReplacement: Equatable, Sendable {
    public let range: NSRange
    public let string: String

    public init(range: NSRange, string: String) {
        self.range = range
        self.string = string
    }
}

enum SpecialCharacterMetrics {
    static let outerInset: CGFloat = 1
    static let strokeWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 3

    private struct LabelKey: Hashable {
        let label: String
        let font: NSFont
    }

    private struct LineKey: Hashable {
        let label: String
        let font: NSFont
        let color: NSColor
    }

    private static var markers: [LabelKey: (width: CGFloat, delegate: CTRunDelegate)] = [:]
    private static var labelLines: [LineKey: CTLine] = [:]

    static func labelFont(for font: NSFont) -> NSFont {
        let size = max(7, (font.pointSize * 0.7).rounded())
        return NSFont(descriptor: font.fontDescriptor, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func horizontalPadding(for font: NSFont) -> CGFloat {
        max(2, (font.pointSize * 0.25).rounded())
    }

    static func labelLine(_ label: String, font: NSFont, color: NSColor) -> CTLine {
        let key = LineKey(label: label, font: font, color: color)
        if let cached = labelLines[key] {
            return cached
        }
        let attributed = NSAttributedString(string: label, attributes: [
            .font: labelFont(for: font),
            .foregroundColor: color
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        labelLines[key] = line
        return line
    }

    static func markerWidth(label: String, font: NSFont) -> CGFloat {
        marker(label: label, font: font)?.width ?? 0
    }

    static func markerDelegate(label: String, font: NSFont) -> CTRunDelegate? {
        marker(label: label, font: font)?.delegate
    }

    private static func marker(label: String, font: NSFont) -> (width: CGFloat, delegate: CTRunDelegate)? {
        let key = LabelKey(label: label, font: font)
        if let cached = markers[key] {
            return cached
        }
        let line = labelLine(label, font: font, color: .black)
        let labelWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let width = (labelWidth + 2 * horizontalPadding(for: font) + 2 * outerInset).rounded(.up)
        guard let delegate = SpecialCharacterRunDelegate.make(width: width, font: font) else { return nil }
        markers[key] = (width, delegate)
        return (width, delegate)
    }
}

enum SpecialCharacterRunDelegate {
    private final class Metrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat

        init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
        }
    }

    static func make(width: CGFloat, font: NSFont) -> CTRunDelegate? {
        let metrics = Metrics(width: width, ascent: font.ascender, descent: -font.descender)
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { reference in
                Unmanaged<Metrics>.fromOpaque(reference).release()
            },
            getAscent: { reference in
                Unmanaged<Metrics>.fromOpaque(reference).takeUnretainedValue().ascent
            },
            getDescent: { reference in
                Unmanaged<Metrics>.fromOpaque(reference).takeUnretainedValue().descent
            },
            getWidth: { reference in
                Unmanaged<Metrics>.fromOpaque(reference).takeUnretainedValue().width
            }
        )
        let reference = Unmanaged.passRetained(metrics).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, reference) else {
            Unmanaged<Metrics>.fromOpaque(reference).release()
            return nil
        }
        return delegate
    }
}
