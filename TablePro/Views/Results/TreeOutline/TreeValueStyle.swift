//
//  TreeValueStyle.swift
//  TablePro
//

import AppKit

internal enum TreeValueStyle {
    /// Fixed system colors do not adapt on an emphasized row the way the label colors do.
    static func textColor(for tone: TreeValueTone, isEmphasized: Bool) -> NSColor {
        isEmphasized ? .alternateSelectedControlTextColor : tone.color
    }

    static func linkRange(in content: TreeRowContent) -> NSRange? {
        guard case .link = content.decoration else { return nil }
        let whole = NSRange(location: 0, length: (content.value as NSString).length)
        let range = NSIntersectionRange(content.valueContentRange, whole)
        return range.length > 0 ? range : nil
    }

    /// No `.link` attribute: a text field cell draws that run in the link color whatever its
    /// foreground, blue on the accent color. `TreeValueField` puts it in the field editor only.
    static func attributedValue(
        _ content: TreeRowContent,
        font: NSFont,
        isEmphasized: Bool
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: content.value,
            attributes: [
                .font: font,
                .foregroundColor: textColor(for: content.tone, isEmphasized: isEmphasized),
                .paragraphStyle: paragraph
            ]
        )
        guard let range = linkRange(in: content) else { return text }
        text.addAttributes(
            [
                .foregroundColor: isEmphasized ? NSColor.alternateSelectedControlTextColor : NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ],
            range: range
        )
        return text
    }
}
