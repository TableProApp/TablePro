//
//  CTLineTypesetData.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import AppKit

/// Represents layout information received from a `CTTypesetter` for a `CTLine`.
struct CTLineTypesetData {
    let ctLine: CTLine
    let descent: CGFloat
    let width: CGFloat
    let height: CGFloat
}
