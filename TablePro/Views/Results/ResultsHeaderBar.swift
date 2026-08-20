//
//  ResultsHeaderBar.swift
//  TablePro
//

import SwiftUI

/// The strip above the result: which view of the object you are looking at, and which result set.
///
/// The mode switcher used to sit in the bottom status bar. The HIG puts view switching in the main
/// window area, and it also keeps the status bar to what it is for, so the switcher moved here and
/// shares the strip the result-set tabs already occupied. A query tab therefore gains no height at
/// all, and the switcher sizes to its own labels instead of the 340pt frame that clipped every
/// translation longer than English.
struct ResultsHeaderBar<Accessory: View>: View {
    let modes: [ResultsViewMode]
    @Binding var selection: ResultsViewMode
    @ViewBuilder let accessory: () -> Accessory

    static var height: CGFloat { 32 }

    var body: some View {
        HStack(spacing: 8) {
            if modes.count > 1 {
                Picker(String(localized: "View Mode"), selection: $selection) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("results-view-mode-picker")
            }

            accessory()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(.bar)
    }
}

extension ResultsHeaderBar where Accessory == EmptyView {
    init(modes: [ResultsViewMode], selection: Binding<ResultsViewMode>) {
        self.init(modes: modes, selection: selection) { EmptyView() }
    }
}
