//
//  SettingsSidebar.swift
//  TablePro
//

import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsTab?
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search")
            )
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 6)

            content
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    @ViewBuilder
    private var content: some View {
        if filteredTabs.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(filteredTabs) { tab in
                    Label(tab.displayName, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var filteredTabs: [SettingsTab] {
        let needle = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter { tab in
            if tab.displayName.lowercased().contains(needle) { return true }
            return tab.searchKeywords.contains { $0.lowercased().contains(needle) }
        }
    }
}
