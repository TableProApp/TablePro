//
//  MarkedRanges.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/17/25.
//

import AppKit

/// Struct for passing attribute and range information easily down into line fragments, typesetters without
/// requiring a reference to the marked text manager.
public struct MarkedRanges {
    let ranges: [NSRange]
    let attributes: [NSAttributedString.Key: Any]
}
