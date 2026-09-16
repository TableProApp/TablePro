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

    /// `.accessoryBar` is macOS 14. `.borderless` is what macOS 13 offers for the same shape: a
    /// label with no resting chrome that still takes the whole control as its hit area.
    @ViewBuilder
    func accessoryBarStyle() -> some View {
        if #available(macOS 14.0, *) {
            buttonStyle(.accessoryBar)
        } else {
            buttonStyle(.borderless)
        }
    }
}
