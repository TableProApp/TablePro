//
//  UserDefinedTypeAwarePicker.swift
//  TablePro
//

import SwiftUI

/// Loads the user-defined types of one scope and hands them to the picker it wraps. The picker
/// opens at once with the engine's own types and gains the user's once the catalog answers, so a
/// slow server never holds the popover closed.
struct UserDefinedTypeAwarePicker<Content: View>: View {
    let scope: DatabaseScope?
    @ViewBuilder let content: ([String]) -> Content

    @State private var userDefinedTypes: [String] = []

    var body: some View {
        content(userDefinedTypes)
            .task(id: scope) {
                guard let scope else { return }
                userDefinedTypes = await UserDefinedTypeSuggestions.load(scope: scope)
            }
    }
}
