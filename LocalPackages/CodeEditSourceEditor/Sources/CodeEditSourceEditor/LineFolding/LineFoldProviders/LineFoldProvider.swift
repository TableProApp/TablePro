//
//  LineFoldProvider.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/7/25.
//

import AppKit
import CodeEditTextView

/// Represents a fold's start or end.
public enum LineFoldProviderLineInfo {
    case startFold(rangeStart: Int, newDepth: Int)
    case endFold(rangeEnd: Int, newDepth: Int)

    var depth: Int {
        switch self {
        case .startFold(_, let newDepth):
            return newDepth
        case .endFold(_, let newDepth):
            return newDepth
        }
    }

    var rangeIndice: Int {
        switch self {
        case .startFold(let rangeStart, _):
            return rangeStart
        case .endFold(let rangeEnd, _):
            return rangeEnd
        }
    }
}

/// ``LineFoldProvider`` is an interface used by the editor to find fold regions in a document.
///
/// The only required method, ``LineFoldProvider/foldLevelAtLine(lineNumber:lineRange:previousDepth:controller:)``,
/// will be called very often. Return as fast as possible from this method, keeping in mind it is taking time on the
/// main thread.
///
/// Ordering between calls is not guaranteed, the provider may restart at any time. The implementation should provide
/// fold info for only the given lines.
@MainActor
public protocol LineFoldProvider: AnyObject {
    func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        controller: TextViewController
    ) -> [LineFoldProviderLineInfo]

    /// The label drawn in place of a collapsed region.
    ///
    /// The provider owns this string because it is the only part of the folding system the host application supplies,
    /// so it is the only part that can reach the application's localized strings.
    func foldPlaceholderLabel(for summary: FoldPlaceholderSummary) -> String
}

public extension LineFoldProvider {
    func foldPlaceholderLabel(for summary: FoldPlaceholderSummary) -> String {
        summary.previewText
    }
}
