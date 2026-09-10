//
//  CodeBlockHeightEstimator.swift
//  TablePro
//

import AppKit

enum CodeBlockHeightEstimator {
    static let minimumHeight: CGFloat = 32
    static let maximumHeight: CGFloat = 400
    static let lineHeightMultiple: CGFloat = 1.2
    private static let verticalInsets: CGFloat = 18
    private static let horizontalInsets: CGFloat = 16

    static func height(for code: String, font: NSFont, availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return fallbackHeight(for: code, font: font) }
        let textWidth = max(availableWidth - horizontalInsets, 1)
        let measured = (code as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        return clamped(ceil(measured * pitchScale(for: font)) + verticalInsets)
    }

    static func fallbackHeight(for code: String, font: NSFont) -> CGFloat {
        let lineCount = (code as NSString).components(separatedBy: "\n").count
        return clamped(CGFloat(lineCount) * editorLineHeight(for: font) + verticalInsets)
    }

    static func editorLineHeight(for font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading) * lineHeightMultiple
    }

    static func extraLineSpacing(for font: NSFont) -> CGFloat {
        max(editorLineHeight(for: font) - layoutLineHeight(for: font), 0)
    }

    private static func layoutLineHeight(for font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    private static func pitchScale(for font: NSFont) -> CGFloat {
        let layoutHeight = layoutLineHeight(for: font)
        guard layoutHeight > 0 else { return lineHeightMultiple }
        return max(editorLineHeight(for: font) / layoutHeight, 1)
    }

    private static func clamped(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), maximumHeight)
    }
}
