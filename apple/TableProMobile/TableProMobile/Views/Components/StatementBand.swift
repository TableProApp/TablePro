import UIKit

@MainActor
final class StatementBand {
    private weak var textView: UITextView?
    private var range: NSRange?

    init(textView: UITextView) {
        self.textView = textView
        guard let manager = textView.textLayoutManager else { return }
        let previous = manager.renderingAttributesValidator
        // A fragment drops its rendering attributes each time it lays out again.
        manager.renderingAttributesValidator = { [weak self] manager, fragment in
            previous?(manager, fragment)
            self?.restore(in: fragment, of: manager)
        }
    }

    func show(_ range: NSRange?) {
        let previous = self.range
        self.range = range
        guard let textView, let manager = textView.textLayoutManager else { return }
        // A band moves and splits with the text it covers, so a range kept from before an edit misses pieces of it.
        manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
        if let range, let textRange = Self.textRange(for: range, in: manager) {
            manager.addRenderingAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, for: textRange)
        }
        guard previous != range else { return }
        // A fragment on screen keeps what it drew until it lays out again, so a moved band would stay where it was.
        relayoutLines(covering: [previous, range].compactMap { $0 }, of: textView, in: manager)
    }

    private func relayoutLines(covering ranges: [NSRange], of textView: UITextView, in manager: NSTextLayoutManager) {
        guard let first = ranges.first else { return }
        let text = textView.textStorage.string as NSString
        let union = ranges.dropFirst().reduce(first, NSUnionRange)
        let lines = text.paragraphRange(for: NSIntersectionRange(union, NSRange(location: 0, length: text.length)))
        guard let textRange = Self.textRange(for: lines, in: manager) else { return }
        manager.invalidateLayout(for: textRange)
    }

    private func restore(in fragment: NSTextLayoutFragment, of manager: NSTextLayoutManager) {
        guard let range,
              let textRange = Self.textRange(for: range, in: manager),
              let overlap = textRange.intersection(fragment.rangeInElement) else { return }
        manager.addRenderingAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, for: overlap)
    }

    private static func textRange(for range: NSRange, in manager: NSTextLayoutManager) -> NSTextRange? {
        guard range.length > 0, let content = manager.textContentManager,
              let start = content.location(manager.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
