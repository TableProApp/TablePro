//
//  SetupGuideFirstConnectionStep.swift
//  TablePro
//

import SwiftUI

// Records the choice only; it runs once the guide closes, so the options step still comes first.
internal struct SetupGuideFirstConnectionStep: View {
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(String(localized: "When you finish"), selection: $model.recorded) {
                Text(verbatim: noChoiceTitle)
                    .tag(SetupGuideFirstConnection?.none)
                Text("Create a new connection")
                    .tag(SetupGuideFirstConnection?.some(.newConnection))
                Text("Open the sample database")
                    .tag(SetupGuideFirstConnection?.some(.sample))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("setup-guide-first-connection")
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var noChoiceTitle: String {
        switch model.importedIds.count {
        case 0: String(localized: "Nothing for now")
        case 1: String(localized: "Open the connection you imported")
        default: String(localized: "Show the connections you imported")
        }
    }
}
