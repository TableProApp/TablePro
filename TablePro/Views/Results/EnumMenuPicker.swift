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
            driftItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: nil)
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
        let selected = Set(
            (currentCsv ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        let menu = NSMenu()
        menu.autoenablesItems = false

        let coordinator = SetSelectionCoordinator(
            allowedValues: allowedValues,
            initialSelection: selected,
            onCommit: onCommit
        )

        for value in allowedValues {
            let item = NSMenuItem(title: value, action: nil, keyEquivalent: "")
            item.target = coordinator
            item.action = #selector(SetSelectionCoordinator.toggle(_:))
            item.representedObject = value
            item.state = selected.contains(value) ? .on : .off
            menu.addItem(item)
        }

        for current in selected where !allowedValues.contains(current) {
            menu.addItem(.separator())
            let driftItem = NSMenuItem(title: current, action: nil, keyEquivalent: "")
            driftItem.target = coordinator
            driftItem.action = #selector(SetSelectionCoordinator.toggle(_:))
            driftItem.representedObject = current
            driftItem.state = .on
            driftItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: nil)
            driftItem.toolTip = String(localized: "Value is not in the declared set.")
            menu.addItem(driftItem)
        }

        menu.delegate = coordinator

        let anchor = NSPoint(x: rect.minX, y: rect.maxY)
        menu.popUp(positioning: nil, at: anchor, in: view)
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
}

@MainActor
private final class SetSelectionCoordinator: NSObject, NSMenuDelegate {
    private let allowedValues: [String]
    private var selection: Set<String>
    private let initialSelection: Set<String>
    private let onCommit: (String) -> Void
    private var committed = false

    init(allowedValues: [String], initialSelection: Set<String>, onCommit: @escaping (String) -> Void) {
        self.allowedValues = allowedValues
        self.selection = initialSelection
        self.initialSelection = initialSelection
        self.onCommit = onCommit
    }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if selection.contains(value) {
            selection.remove(value)
            sender.state = .off
        } else {
            selection.insert(value)
            sender.state = .on
        }
        committed = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard committed, selection != initialSelection else { return }
        let ordered = allowedValues.filter(selection.contains)
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
