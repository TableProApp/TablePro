//
//  SourceEditorState.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/19/25.
//

import AppKit

public struct SourceEditorState: Equatable, Hashable, Sendable, Codable {
    public var cursorPositions: [CursorPosition]?
    public var scrollPosition: CGPoint?
    public var findText: String?
    public var replaceText: String?
    public var findPanelVisible: Bool?

    public init(
        cursorPositions: [CursorPosition]? = nil,
        scrollPosition: CGPoint? = nil,
        findText: String? = nil,
        replaceText: String? = nil,
        findPanelVisible: Bool? = nil
    ) {
        self.cursorPositions = cursorPositions
        self.scrollPosition = scrollPosition
        self.findText = findText
        self.replaceText = replaceText
        self.findPanelVisible = findPanelVisible
    }
}
