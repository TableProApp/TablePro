//
//  HighlightRange.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/14/22.
//

import Foundation

/// This struct represents a range to highlight, as well as the capture name for syntax coloring.
public struct HighlightRange: Hashable, Sendable {
    public let range: NSRange
    public let capture: CaptureName?
    public let modifiers: CaptureModifierSet

    public init(range: NSRange, capture: CaptureName?, modifiers: CaptureModifierSet = []) {
        self.range = range
        self.capture = capture
        self.modifiers = modifiers
    }
}

extension HighlightRange: CustomDebugStringConvertible {
    public var debugDescription: String {
        if capture == nil && modifiers.isEmpty {
            "\(range) (empty)"
        } else {
            "\(range) (\(capture?.stringValue ?? "No Capture")) \(modifiers.values.map({ $0.stringValue }))"
        }
    }
}
