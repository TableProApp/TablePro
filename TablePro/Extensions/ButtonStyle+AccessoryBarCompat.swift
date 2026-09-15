//
//  ButtonStyle+AccessoryBarCompat.swift
//  TablePro
//

import SwiftUI

internal extension View {
    /// `.accessoryBarAction` is macOS 14. `.link` is the closest thing macOS 13 offers for a
    /// borderless action sitting in a bar: the same plain, tinted label with no button chrome.
    @ViewBuilder
    func accessoryBarActionStyle() -> some View {
        if #available(macOS 14.0, *) {
            buttonStyle(.accessoryBarAction)
        } else {
            buttonStyle(.link)
        }
    }
}
