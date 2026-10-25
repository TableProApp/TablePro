import AppKit

@MainActor
enum EnumMenuPicker {
    static func presentEnum(
        relativeTo rect: NSRect,
        in view: NSView,
        allowedValues: [String],
        currentValue: String?,
        isNullable: Bool,
        defaultValue: String?,
        onCommit: @escaping (String?) -> Void
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if isNullable {
            let nullItem = NSMenuItem(
                title: String(localized: "NULL"),
                action: nil,
                keyEquivalent: ""
            )
            nullItem.attributedTitle = NSAttributedString(
                string: String(localized: "NULL"),
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize).italic()]
            )
            nullItem.target = ItemTarget.shared
            nullItem.action = #selector(ItemTarget.invoke(_:))
            nullItem.representedObject = ItemPayload(value: nil, onCommit: onCommit)
            if currentValue == nil { nullItem.state = .on }
            menu.addItem(nullItem)
            menu.addItem(.separator())
        }

        for value in allowedValues {
            let item = NSMenuItem(title: value, action: nil, keyEquivalent: "")
            item.target = ItemTarget.shared
            item.action = #selector(ItemTarget.invoke(_:))
            item.representedObject = ItemPayload(value: value, onCommit: onCommit)
            if currentValue == value { item.state = .on }
            menu.addItem(item)
        }

        if let current = currentValue,
           !current.isEmpty,
           !allowedValues.contains(current) {
            menu.addItem(.separator())
            let driftItem = NSMenuItem(title: current, action: nil, keyEquivalent: "")
            driftItem.target = ItemTarget.shared
            driftItem.action = #selector(ItemTarget.invoke(_:))
            driftItem.representedObject = ItemPayload(value: current, onCommit: onCommit)
            driftItem.setInformativeImage(NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: nil))
            driftItem.toolTip = String(localized: "Value is not in the declared enum.")
            driftItem.state = .on
            menu.addItem(driftItem)
        }

        if currentValue == nil || (currentValue?.isEmpty ?? true),
           let defaultValue,
           allowedValues.contains(defaultValue) {
            menu.items.first(where: { $0.title == defaultValue })?.image = NSImage(
                systemSymbolName: "arrow.uturn.left.circle", accessibilityDescription: nil
            )
        }

        let anchor = NSPoint(x: rect.minX, y: rect.maxY)
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    static func presentSet(
        relativeTo rect: NSRect,
        in view: NSView,
        allowedValues: [String],
        currentCsv: String?,
        onCommit: @escaping (String) -> Void
    ) {
        let menu = makeSetMenu(allowedValues: allowedValues, currentCsv: currentCsv, onCommit: onCommit)
        let anchor = NSPoint(x: rect.minX, y: rect.maxY)
        menu.popUp(positioning: nil, at: anchor, in: view)
    }

    // menuDidClose runs before the chosen item's action (interaction 1), so each pick commits from its own action.
    static func makeSetMenu(
        allowedValues: [String],
        currentCsv: String?,
        onCommit: @escaping (String) -> Void
    ) -> NSMenu {
        let selected = Set(
            (currentCsv ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        let selection = SetSelection(allowedValues: allowedValues, selected: selected, onCommit: onCommit)

        for value in allowedValues {
            let item = NSMenuItem(title: value, action: #selector(ItemTarget.toggle(_:)), keyEquivalent: "")
            item.target = ItemTarget.shared
            item.representedObject = SetItemPayload(value: value, selection: selection)
            item.state = selected.contains(value) ? .on : .off
            menu.addItem(item)
        }

        for current in selected.sorted() where !allowedValues.contains(current) {
            menu.addItem(.separator())
            let driftItem = NSMenuItem(title: current, action: #selector(ItemTarget.toggle(_:)), keyEquivalent: "")
            driftItem.target = ItemTarget.shared
            driftItem.representedObject = SetItemPayload(value: current, selection: selection)
            driftItem.state = .on
            driftItem.setInformativeImage(NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: nil))
            driftItem.toolTip = String(localized: "Value is not in the declared set.")
            menu.addItem(driftItem)
        }
        return menu
    }
}

private struct ItemPayload {
    let value: String?
    let onCommit: (String?) -> Void
}

@MainActor
private final class ItemTarget: NSObject {
    static let shared = ItemTarget()

    @objc func invoke(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ItemPayload else { return }
        payload.onCommit(payload.value)
    }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SetItemPayload else { return }
        payload.selection.toggle(payload.value)
    }
}

private struct SetItemPayload {
    let value: String
    let selection: SetSelection
}

// The declared order first, then any value outside the declaration, so the stored list reads the same each time.
@MainActor
private final class SetSelection {
    private let allowedValues: [String]
    private let initial: Set<String>
    private let onCommit: (String) -> Void

    init(allowedValues: [String], selected: Set<String>, onCommit: @escaping (String) -> Void) {
        self.allowedValues = allowedValues
        self.initial = selected
        self.onCommit = onCommit
    }

    func toggle(_ value: String) {
        var selection = initial
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
        let ordered = allowedValues.filter { selection.contains($0) }
            + selection.filter { !allowedValues.contains($0) }.sorted()
        onCommit(ordered.joined(separator: ","))
    }
}

private extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
