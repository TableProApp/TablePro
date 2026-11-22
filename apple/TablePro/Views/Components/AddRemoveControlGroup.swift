//
//  AddRemoveControlGroup.swift
//  TablePro
//

import AppKit
import SwiftUI

// Borderless glyphs split by a separator, as System Settings draws a list's bar; the navigation ControlGroup is back and forward.
struct AddRemoveControlGroup: View {
    let addLabel: String
    let removeLabel: String
    var canAdd = true
    var canRemove = true
    // A withheld control sets its help to the reason, the only place a disabled button explains itself.
    var addHelp: String?
    var removeHelp: String?
    var addIdentifier: String?
    var removeIdentifier: String?
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ListBarButton(
                label: addLabel,
                systemImage: "plus",
                help: addHelp,
                identifier: addIdentifier,
                action: onAdd
            )
            .disabled(!canAdd)

            ListBarSeparator()

            ListBarButton(
                label: removeLabel,
                systemImage: "minus",
                help: removeHelp,
                identifier: removeIdentifier,
                action: onRemove
            )
            .disabled(!canRemove)
        }
        .fixedSize()
    }
}

// Measured from System Settings > General > Login Items on macOS 27.
enum ListBarMetrics {
    static let contentHeight: CGFloat = 23
    static let height: CGFloat = contentHeight + 1
    static let buttonWidth: CGFloat = 24
    static let separatorHeight: CGFloat = 16
}

struct ListBarButton: View {
    let label: String
    let systemImage: String
    var help: String?
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: NSFont.smallSystemFontSize))
                .frame(width: ListBarMetrics.buttonWidth, height: ListBarMetrics.contentHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}

struct ListBarSeparator: View {
    var body: some View {
        Divider()
            .frame(height: ListBarMetrics.separatorHeight)
    }
}

struct ListBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
            .frame(minHeight: ListBarMetrics.contentHeight)
        }
    }
}

extension View {
    // An overlay, not a safe area inset: an inset shrinks a bordered list and leaves the bar outside its border.
    // The caller's list height counts ListBarMetrics.height, so no row ever sits under the bar.
    func listBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        overlay(alignment: .bottom) {
            ListBar(content: content)
        }
    }
}
