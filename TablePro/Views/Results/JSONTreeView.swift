//
//  JSONTreeView.swift
//  TablePro
//

import SwiftUI

internal struct JSONTreeView: View {
    let rootNode: JSONTreeNode
    @Binding var searchText: String

    var body: some View {
        FilterableTreeView(
            rootNode: rootNode,
            searchText: $searchText,
            fullValueModeName: String(localized: "Text")
        )
    }
}
