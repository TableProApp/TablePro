//
//  FindPanelMode.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 4/18/25.
//

enum FindPanelMode: CaseIterable {
    case find
    case replace

    var displayName: String {
        switch self {
        case .find:
            return String(localized: "Find")
        case .replace:
            return String(localized: "Replace")
        }
    }
}
