//
//  View+AlternatingRowsCompat.swift
//  TablePro
//

import SwiftUI

internal extension View {
    /// `alternatingRowBackgrounds()` is macOS 14. Before it a SwiftUI `Table` drew a plain
    /// background, which is what macOS 13 gets here.
    @ViewBuilder
    func alternatingRowBackgroundsCompat() -> some View {
        if #available(macOS 14.0, *) {
            alternatingRowBackgrounds(.enabled)
        } else {
            self
        }
    }
}
