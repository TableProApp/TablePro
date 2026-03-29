//
//  LineBreakStrategy.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/19/23.
//

/// Options for breaking lines when they cannot fit in the viewport.
public enum LineBreakStrategy {
    /// Break lines at word boundaries when possible.
    case word
    /// Break lines at the nearest character, regardless of grouping.
    case character
}
