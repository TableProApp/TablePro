//
//  JumpToDefinitionModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/23/25.
//

import AppKit
import CodeEditTextView

/// Manages two things:
/// - Finding a range to hover when pressing `cmd` using tree-sitter.
/// - Utilizing the `JumpToDefinitionDelegate` object to perform a jump, providing it with ranges and
///   strings as necessary.
/// - Presenting a popover when multiple options exist to jump to.
@MainActor
final class JumpToDefinitionModel {
    static let emphasisId = "jumpToDefinition"

    weak var delegate: JumpToDefinitionDelegate?
    weak var treeSitterClient: TreeSitterClient?

    weak var controller: TextViewController?

    private(set) public var hoveredRange: NSRange?

    private var hoverRequestTask: Task<Void, Never>?
    private var jumpRequestTask: Task<Void, Never>?

    private var currentLinks: [JumpToDefinitionLink]?

    private var textView: TextView? {
        controller?.textView
    }

    init(controller: TextViewController?, treeSitterClient: TreeSitterClient?, delegate: JumpToDefinitionDelegate?) {
        self.controller = controller
        self.treeSitterClient = treeSitterClient
        self.delegate = delegate
    }

    // MARK: - Tree Sitter

    /// Query the tree-sitter client for a valid range to query for definitions.
    /// - Parameter location: The current cursor location.
    /// - Returns: A range that contains a potential identifier to look up.
    private func findDefinitionRange(at location: Int) async -> NSRange? {
        guard let nodes = try? await treeSitterClient?.nodesAt(location: location),
              let node = nodes.first(where: { $0.node.nodeType?.contains("identifier") == true }) else {
            cancelHover()
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return node.node.range
    }

    // MARK: - Jump Action

    /// Performs the jump action.
    /// - Parameter location: The location to query the delegate for.
    func performJump(at location: NSRange) {
        jumpRequestTask?.cancel()
        jumpRequestTask = Task {
            currentLinks = nil
            guard let controller,
                  let links = await delegate?.queryLinks(forRange: location, textView: controller),
                  !links.isEmpty else {
                NSSound.beep()
                if let textView {
                    BezelNotification.show(symbolName: "questionmark", over: textView)
                }
                return
            }
            if links.count == 1 {
                let link = links[0]
                if link.url != nil {
                    delegate?.openLink(link: link)
                } else {
                    textView?.selectionManager.setSelectedRange(link.targetRange.range)
                }

                textView?.scrollSelectionToVisible()
            } else {
                presentLinkPopover(on: location, links: links)
            }

            cancelHover()
        }
    }

    // MARK: - Link Popover

    private func presentLinkPopover(on range: NSRange, links: [JumpToDefinitionLink]) {
        let halfway = range.location + (range.length / 2)
        let range = NSRange(location: halfway, length: 0)
        guard let controller,
              let position = controller.resolveCursorPosition(CursorPosition(range: range)) else {
            return
        }
        currentLinks = links
        SuggestionController.shared.showCompletions(
            textView: controller,
            delegate: self,
            cursorPosition: position,
            asPopover: true
        )
    }

    // MARK: - Local Link

    private func openLocalLink(link: JumpToDefinitionLink) {
        guard let controller = controller, let range = controller.resolveCursorPosition(link.targetRange) else {
            return
        }
        controller.textView.selectionManager.setSelectedRange(range.range)
        controller.textView.scrollSelectionToVisible()
    }

    // MARK: - Mouse Interaction

    func mouseHovered(windowCoordinates: CGPoint) {
        guard delegate != nil,
              let textViewCoords = textView?.convert(windowCoordinates, from: nil),
              let location = textView?.layoutManager.textOffsetAtPoint(textViewCoords),
              location < textView?.textStorage.length ?? 0 else {
            cancelHover()
            return
        }

        if hoveredRange?.contains(location) == false {
            cancelHover()
        }

        hoverRequestTask?.cancel()
        hoverRequestTask = Task {
            guard let newRange = await findDefinitionRange(at: location) else { return }
            updateHoveredRange(to: newRange)
        }
    }

    func cancelHover() {
        if (textView as? SourceEditorTextView)?.additionalCursorRects.isEmpty != true {
            (textView as? SourceEditorTextView)?.additionalCursorRects = []
            textView?.resetCursorRects()
        }
        guard hoveredRange != nil else { return }
        hoveredRange = nil
        hoverRequestTask?.cancel()
        textView?.emphasisManager?.removeEmphases(for: Self.emphasisId)
    }

    private func updateHoveredRange(to newRange: NSRange) {
        let rects = textView?.layoutManager.rectsFor(range: newRange).map { ($0, NSCursor.pointingHand) } ?? []
        (textView as? SourceEditorTextView)?.additionalCursorRects = rects
        textView?.resetCursorRects()

        hoveredRange = newRange

        textView?.emphasisManager?.removeEmphases(for: Self.emphasisId)
        let color = textView?.selectionManager.selectionBackgroundColor ?? .selectedTextBackgroundColor
        textView?.emphasisManager?.addEmphasis(
            Emphasis(range: newRange, style: .outline( color: color, fill: true)),
            for: Self.emphasisId
        )
    }
}

extension JumpToDefinitionModel: CodeSuggestionDelegate {
    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let links = currentLinks else { return nil }
        defer { self.currentLinks = nil }
        return (cursorPosition, links)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let link = item as? JumpToDefinitionLink else { return }
        if link.url != nil {
            delegate?.openLink(link: link)
        } else {
            openLocalLink(link: link)
        }
    }
}
