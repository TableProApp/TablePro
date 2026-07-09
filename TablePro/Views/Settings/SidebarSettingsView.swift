//
//  SidebarSettingsView.swift
//  TablePro
//

import SwiftUI

struct SidebarSettingsView: View {
    @Binding var general: GeneralSettings
    @AppStorage(SidebarPersistenceKey.defaultLayout) private var defaultSidebarLayout: SidebarLayout = .flat

    var body: some View {
        Form {
            Section("Tables") {
                Toggle("Show recent tables", isOn: $general.showRecentTables)
                    .help("Adds a Recent section at the top of the Tables sidebar with the last tables you opened per connection and database.")

                Toggle("Show object comments", isOn: $general.showObjectComments)
                    .help("Shows database object comments next to tables in the sidebar and in grid column headers.")
            }

            Section {
                Picker("Default layout for new connections:", selection: $defaultSidebarLayout) {
                    Text("List").tag(SidebarLayout.flat)
                    Text("Tree").tag(SidebarLayout.tree)
                }
                .help(String(localized: "Layout for new connections on servers that support a database tree. Switch the current connection from the View menu."))
            } header: {
                Text("Layout")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    SidebarSettingsView(general: .constant(.default))
        .frame(width: 450, height: 500)
}
