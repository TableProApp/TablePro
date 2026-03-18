//
//  PluginIconView.swift
//  TablePro

import AppKit
import SwiftUI

struct PluginIconView: View {
    let name: String

    var body: some View {
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            Image(systemName: name)
        } else {
            Image(name)
                .renderingMode(.template)
        }
    }
}
