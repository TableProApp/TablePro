//
//  FilterOperatorMenuTitle.swift
//  TablePro
//

import SwiftUI

// As wide as the widest operator, like a pop-up button, so every row's value starts at one x.
struct FilterOperatorMenuTitle: View {
    let filterOperator: FilterOperator
    let showsCaseIndicator: Bool
    let reservesCaseIndicator: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            title(filterOperator, showsCaseIndicator: showsCaseIndicator)
            ForEach(FilterOperator.allCases) { candidate in
                title(candidate, showsCaseIndicator: reservesCaseIndicator)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
    }

    private func title(_ filterOperator: FilterOperator, showsCaseIndicator: Bool) -> some View {
        HStack(spacing: 3) {
            Text(filterOperator.displayName)
            if showsCaseIndicator {
                Image(systemName: "textformat")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
