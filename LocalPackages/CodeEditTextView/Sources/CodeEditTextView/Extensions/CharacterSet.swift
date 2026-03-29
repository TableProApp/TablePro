//
//  CharacterSet.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 3/29/25.
//

import Foundation

extension CharacterSet {
    /// Returns a character set containing the characters common in code names
    static let codeIdentifierCharacters: CharacterSet = .alphanumerics
        .union(.init(charactersIn: "_"))
}
