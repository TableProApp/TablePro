//
//  CodeSuggestionEntry.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit
import SwiftUI

/// Represents an item that can be displayed in the code suggestion view
public protocol CodeSuggestionEntry {
    var label: String { get }
    var detail: String? { get }
    var documentation: String? { get }

    /// Leave as `nil` if the link is in the same document.
    var pathComponents: [String]? { get }
    var targetPosition: CursorPosition? { get }
    var sourcePreview: String? { get }

    var image: Image { get }
    var imageColor: Color { get }

    var deprecated: Bool { get }
}
