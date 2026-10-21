//
//  TextView+Insert.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

extension TextView {
    override public func insertNewline(_ sender: Any?) {
        var attachments: [AnyTextAttachment] = selectionManager.textSelections.compactMap({ selection in
            let content = layoutManager.contentRun(at: selection.range.location)
            if case let .attachment(attachment) = content?.data, attachment.range == selection.range {
                return attachment
            }
            return nil
        })

        if !attachments.isEmpty {
            for attachment in attachments.sorted(by: { $0.range.location > $1.range.location }) {
                performAttachmentAction(attachment: attachment)
            }
            return
        }

        insertText(layoutManager.detectedLineEnding.rawValue)
    }

    override public func insertTab(_ sender: Any?) {
        insertText("\t")
    }

    // A bare line ending, without the auto-indent Return gets: `Ctrl+O` follows it with one `moveBackward:` and
    // expects the caret back where it was.
    override public func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        guard isEditable else { return }
        let lineEnding = layoutManager.detectedLineEnding.rawValue
        replaceVerbatim(selectionManager.textSelections.map { TextReplacement(range: $0.range, string: lineEnding) })
    }

    // This view is never a field editor, so a tab is a tab.
    override public func insertTabIgnoringFieldEditor(_ sender: Any?) {
        insertTab(sender)
    }

    override public func yank(_ sender: Any?) {
        insertYank(KillRing.shared.yank(), replacing: nil, selects: false)
    }

    // Not in any header, but `NSTextView` answers it: the next call swaps the selected yank for the next older entry.
    @objc func yankAndSelect(_ sender: Any?) {
        let ring = KillRing.shared
        if let previous = ring.yank(continuing: killContinuation) {
            insertYank(ring.rotate(), replacing: previous.ranges, selects: true)
        } else {
            insertYank(ring.yank(), replacing: nil, selects: true)
        }
    }

    // Emacs's yank-pop: right after a yank, swaps the yanked text for the next older entry.
    @objc public func yankPop(_ sender: Any?) {
        let ring = KillRing.shared
        guard isEditable, let previous = ring.yank(continuing: killContinuation) else {
            NSSound.beep()
            return
        }
        insertYank(ring.rotate(), replacing: previous.ranges, selects: false)
    }

    private func insertYank(_ strings: [String], replacing previousRanges: [NSRange]?, selects: Bool) {
        guard isEditable, !strings.isEmpty else { return }
        let targets = (previousRanges ?? selectionManager.textSelections.map(\.range))
            .sorted(by: { $0.location < $1.location })
        guard !targets.isEmpty else { return }

        // One string per cursor when the counts match, as a multi-cursor kill left them; otherwise every cursor gets
        // the whole entry.
        let pieces = strings.count == targets.count
            ? strings
            : Array(repeating: strings.joined(separator: "\n"), count: targets.count)
        replaceVerbatim(zip(targets, pieces).map { TextReplacement(range: $0, string: $1) })

        var inserted: [NSRange] = []
        var shift = 0
        for (range, piece) in zip(targets, pieces) {
            let length = (piece as NSString).length
            inserted.append(NSRange(location: range.location + shift, length: length))
            shift += length - range.length
        }

        selectionManager.setSelectedRanges(
            selects ? inserted : inserted.map { NSRange(location: $0.max, length: 0) }
        )
        KillRing.shared.didYank(KillRing.Yank(continuation: killContinuation, ranges: inserted))
    }
}
