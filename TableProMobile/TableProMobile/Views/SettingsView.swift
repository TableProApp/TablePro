//
//  SettingsView.swift
//  TableProMobile
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("com.TablePro.settings.shareAnalytics") private var shareAnalytics: Bool = true

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle(String(localized: "Share anonymous usage data"), isOn: $shareAnalytics)

                Text("Help improve TablePro by sharing anonymous usage statistics (no personal data or queries).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent(String(localized: "Version")) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
                LabeledContent(String(localized: "Build")) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                }
            }
        }
        .navigationTitle(String(localized: "Settings"))
    }
}
