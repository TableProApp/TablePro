//
//  FavoriteDatabaseFilterBar.swift
//  TablePro
//

import SwiftUI

internal struct FavoriteDatabaseFilterBar: View {
    @Binding internal var selection: FavoriteDatabaseEnvironmentFilter

    internal var body: some View {
        HStack(spacing: 6) {
            Label(String(localized: "Environment"), systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker(String(localized: "Environment"), selection: $selection) {
                ForEach(FavoriteDatabaseEnvironmentFilter.allCases, id: \.self) { filter in
                    Text(filter.title)
                        .tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
