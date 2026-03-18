//
//  JumpToDefinitionLink.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/23/25.
//

import Foundation
import SwiftUI

public struct JumpToDefinitionLink: Identifiable, Sendable, CodeSuggestionEntry {
    public var id: String { url?.absoluteString ?? "\(targetRange)" }
    /// Leave as `nil` if the link is in the same document.
    public let url: URL?
    public var targetPosition: CursorPosition? {
        targetRange
    }
    public let targetRange: CursorPosition

    public let label: String
    public var detail: String? { url?.lastPathComponent }
    public var documentation: String?

    public let sourcePreview: String?
    public let image: Image
    public let imageColor: Color

    public var pathComponents: [String]? { url?.relativePath.components(separatedBy: "/") ?? [] }
    public var deprecated: Bool { false }

    public init(
        url: URL?,
        targetRange: CursorPosition,
        typeName: String,
        sourcePreview: String,
        documentation: String?,
        image: Image = Image(systemName: "dot.square.fill"),
        imageColor: Color = Color(NSColor.lightGray)
    ) {
        self.url = url
        self.targetRange = targetRange
        self.label = typeName
        self.documentation = documentation
        self.sourcePreview = sourcePreview
        self.image = image
        self.imageColor = imageColor
    }
}
