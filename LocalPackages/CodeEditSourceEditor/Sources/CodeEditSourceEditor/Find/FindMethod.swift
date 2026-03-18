//
//  FindMethod.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 5/2/25.
//

enum FindMethod: CaseIterable {
    case contains
    case matchesWord
    case startsWith
    case endsWith
    case regularExpression

    var displayName: String {
        switch self {
        case .contains:
            return "Contains"
        case .matchesWord:
            return "Matches Word"
        case .startsWith:
            return "Starts With"
        case .endsWith:
            return "Ends With"
        case .regularExpression:
            return "Regular Expression"
        }
    }
}
