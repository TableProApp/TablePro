//
//  QueryConnectionPicker.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The two-row query bar's leading control: the connection the tab runs on, and a menu of the saved
/// connections to move it to.
///
/// The list is read when the control appears and again when the library changes, never in `body`,
/// so typing in the editor, which redraws the bar on every key, reads no storage.
struct QueryConnectionPicker: View {
    /// Wide enough for a typical connection name, so a long one truncates rather than pushing the
    /// database picker off the row.
    private static let nameWidth: CGFloat = 200

    let model: QueryConnectionPickerModel

    @State private var items: [QueryConnectionMenuItem] = []

    var body: some View {
        Menu {
            menuContent(items)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: model.color.queryBarMark())
                Text(model.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.nameWidth, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(format: String(localized: "Connection: %@"), model.name))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(!model.canMove)
        .help(model.hint)
        // The label's own name reaches VoiceOver only through the menu, which names it only beside `.contain`.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: String(localized: "Connection: %@"), model.name))
        .accessibilityIdentifier("query-connection")
        .onAppear(perform: reload)
        .onReceive(AppEvents.shared.connectionUpdated) { _ in reload() }
        .onReceive(AppEvents.shared.connectionListStateChanged) { reload() }
    }

    private func reload() {
        let loaded = QueryConnectionMenu.load()
        guard loaded != items else { return }
        items = loaded
    }

    /// Type-erased because a group's submenu holds the same content one level down.
    private func menuContent(_ items: [QueryConnectionMenuItem]) -> AnyView {
        AnyView(ForEach(items) { item in
            switch item {
            case .group(_, let name, let children):
                Menu(name) { menuContent(children) }
            case .connection(let id, let name, let color):
                Button {
                    model.choose(id)
                } label: {
                    if id == model.connectionId {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Label { Text(name) } icon: { Image(nsImage: color.queryBarMark()) }
                    }
                }
            }
        })
    }
}

private extension ConnectionColor {
    /// The connection's color as a dot. An image rather than a tinted symbol, because a menu item
    /// draws a symbol as a template in its text color. A connection with no color draws a ring, so
    /// every row and the label keep the mark in the same place.
    func queryBarMark(diameter: CGFloat = 10) -> NSImage {
        let fill: NSColor? = isDefault ? nil : NSColor(color)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let oval = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let fill {
                fill.setFill()
                oval.fill()
                NSColor.separatorColor.setStroke()
                oval.lineWidth = 0.5
            } else {
                NSColor.secondaryLabelColor.setStroke()
                oval.lineWidth = 1
            }
            oval.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = displayName
        return image
    }
}
