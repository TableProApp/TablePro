//
//  PasteboardTextReader.swift
//  CodeEditTextView
//

import AppKit

/// Resolves plain text from a pasteboard the way AppKit's own plain-text `NSTextView` does.
///
/// `NSPasteboard.string(forType: .string)` on its own answers for one flavour. It promotes RTF,
/// because writing RTF also writes `public.utf8-plain-text`, but it returns nil for a
/// file-URL-only pasteboard, which a plain-text `NSTextView` pastes as the path. Reading through
/// `readObjects(forClasses: [NSString.self])` is no better: it returns an empty array for a file
/// URL and for RTF-only content alike.
///
/// The type order follows `NSTextView.readablePasteboardTypes` for a plain-text view, so the
/// richest available representation wins and everything is flattened to a string.
public enum PasteboardTextReader {
    /// Ordered by preference. Types that carry no text (images, colours, fonts, rulers) are
    /// deliberately absent: a code editor has nothing to insert for them, and claiming them would
    /// enable Paste for content it drops.
    ///
    /// `public.html` is absent too, although `NSTextView` reads it. The only way to flatten it is
    /// `NSAttributedString`'s HTML importer, which was measured fetching every remote subresource
    /// the markup references: a page that puts `<img src="http://…">` on the clipboard turns a
    /// paste into an outbound request from the user's machine, and this app reaches hosts a
    /// browser cannot. RTF was measured under the same probe and fetches nothing. Browsers write
    /// plain text alongside their HTML, so `.string` answers for them first either way, and an
    /// HTML-only clipboard now leaves Paste disabled rather than silently doing nothing.
    public static let readableTypes: [NSPasteboard.PasteboardType] = [
        .string,
        .rtf,
        .rtfd,
        .fileURL
    ]

    /// Whether the pasteboard carries something this reader can turn into text.
    ///
    /// Checks type availability only, so menu validation can run it on every pass without
    /// decoding a large RTF or HTML payload.
    public static func hasText(in pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: readableTypes) != nil
    }

    /// The pasteboard's contents as plain text, or nil when it carries nothing readable.
    ///
    /// A pasteboard holding several items resolves to the first item's representation, which is
    /// what `string(forType:)` already did.
    public static func plainText(in pasteboard: NSPasteboard = .general) -> String? {
        guard let type = pasteboard.availableType(from: readableTypes) else { return nil }
        return plainText(
            forType: type,
            string: pasteboard.string(forType: type),
            data: pasteboard.data(forType: type)
        )
    }

    /// The coercion itself, split from the pasteboard so it can be tested without one.
    public static func plainText(
        forType type: NSPasteboard.PasteboardType,
        string: String?,
        data: Data?
    ) -> String? {
        switch type {
        case .fileURL:
            guard let string, let url = URL(string: string), url.isFileURL else { return string }
            return url.path
        case .rtf, .rtfd:
            guard let data, let documentType = documentType(for: type) else { return string }
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: documentType],
                documentAttributes: nil
            )
            return attributed?.string ?? string
        default:
            return string
        }
    }

    private static func documentType(
        for type: NSPasteboard.PasteboardType
    ) -> NSAttributedString.DocumentType? {
        switch type {
        case .rtf: return .rtf
        case .rtfd: return .rtfd
        default: return nil
        }
    }
}
