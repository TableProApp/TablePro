//
//  InvisibleCharacterTextDisplay.swift
//  TablePro
//

import AppKit
import TableProTextEngine

// Marks a TextKit 2 view's invisible characters as the editor does. Each paragraph is laid out from a
// copy with every mark an attachment of the same UTF-16 length, so editing and copy see the real text.
internal final class InvisibleCharacterTextDisplay: NSObject, NSTextContentStorageDelegate {
    private static let objectReplacement = "\u{FFFC}"
    private static let clusterExtender = "\u{034F}"
    // The editor's cap per line: past it a value of control bytes would lay out one attachment each.
    private static let maximumMarksPerParagraph = SpecialCharacterStyle().maximumMarksPerLine

    private weak var contentStorage: NSTextContentStorage?

    internal var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            relayOut()
        }
    }

    private init(contentStorage: NSTextContentStorage, isEnabled: Bool) {
        self.contentStorage = contentStorage
        self.isEnabled = isEnabled
    }

    // Nil for a TextKit 1 view, which has no paragraphs to swap. The caller holds the result:
    // the content storage keeps its delegate weakly.
    @MainActor
    internal static func install(on textView: NSTextView, isEnabled: Bool) -> InvisibleCharacterTextDisplay? {
        guard let storage = textView.textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let display = InvisibleCharacterTextDisplay(contentStorage: storage, isEnabled: isEnabled)
        storage.delegate = display
        // A view already laid out keeps its cached paragraphs until asked for them again.
        if isEnabled {
            display.relayOut()
        }
        return display
    }

    internal func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard isEnabled, let storage = textContentStorage.textStorage else { return nil }
        let text = storage.string as NSString
        let marked = Self.specialCharacters(in: text, range: range)
        guard !marked.isEmpty else { return nil }

        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        for classified in marked {
            let local = NSRange(location: classified.range.location - range.location, length: classified.range.length)
            var attributes = paragraph.attributes(at: local.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let mark = SpecialCharacterMarkImage(classified, in: text, font: font, color: .systemOrange)
            let attachment = NSTextAttachment()
            attachment.image = mark.image
            attachment.bounds = mark.bounds

            let placeholder = NSMutableAttributedString(
                string: String(repeating: Self.clusterExtender, count: local.length - 1),
                attributes: attributes
            )
            attributes[.attachment] = attachment
            placeholder.insert(NSAttributedString(string: Self.objectReplacement, attributes: attributes), at: 0)
            paragraph.replaceCharacters(in: local, with: placeholder)
        }
        return NSTextParagraph(attributedString: paragraph)
    }

    private static func specialCharacters(in text: NSString, range: NSRange) -> [ClassifiedSpecialCharacter] {
        var found: [ClassifiedSpecialCharacter] = []
        var index = range.location
        let end = min(NSMaxRange(range), text.length)
        while index < end, found.count < maximumMarksPerParagraph {
            guard let classified = SpecialCharacter.classify(in: text, at: index),
                  NSMaxRange(classified.range) <= end else {
                index += 1
                continue
            }
            found.append(classified)
            index = NSMaxRange(classified.range)
        }
        return found
    }

    // An attributes-only edit makes the content storage ask for every paragraph again, leaving the
    // text, the selection and the undo stack as they were.
    private func relayOut() {
        guard let contentStorage, let storage = contentStorage.textStorage, storage.length > 0 else { return }
        contentStorage.performEditingTransaction {
            storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
        }
    }
}
