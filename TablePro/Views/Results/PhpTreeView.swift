//
//  PhpTreeView.swift
//  TablePro
//

import SwiftUI

internal struct PhpTreeView: View {
    let rootNode: PhpTreeNode
    @Binding var searchText: String

    var body: some View {
        FilterableTreeView(
            rootNode: rootNode,
            searchText: $searchText,
            fullValueModeName: String(localized: "Raw")
        )
    }
}
