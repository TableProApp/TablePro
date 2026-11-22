//
//  WelcomeTagFilterBar.swift
//  TablePro
//

import AppKit
import TableProConnectionLibrary

// The scope bar idiom of Finder's search and Mail's filter: AppKit has no public API for tokens
// in a search field, so the active tag filters sit above the list, one toggle per tag.
@MainActor
internal final class WelcomeTagFilterBar: NSView {
    private let viewModel: WelcomeViewModel
    private let stack = NSStackView()
    private var tagIdsByButton: [ObjectIdentifier: UUID] = [:]
    private(set) var tagButtons: [NSButton] = []
    private(set) var matchPopUp: NSPopUpButton?
    private(set) lazy var clearButton: NSButton = {
        let button = NSButton(
            title: String(localized: "Clear Filters"),
            target: self,
            action: #selector(clearTagFilters(_:))
        )
        button.bezelStyle = .accessoryBarAction
        return button
    }()

    internal init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        // Many active tags shrink their buttons rather than widen the fixed-size window.
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Filter by Tag"))
        setAccessibilityIdentifier("welcome-tag-filter-bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeTagFilterBar does not support NSCoder init")
    }

    internal func apply(_ filter: WelcomeTagFilter) {
        tagIdsByButton = [:]
        tagButtons = filter.tags.map(makeTagButton)
        var leading: [NSView] = tagButtons
        if filter.offersMatch {
            let popUp = matchPopUp ?? makeMatchPopUp()
            popUp.selectItem(at: LibraryTagMatch.allCases.firstIndex(of: filter.match) ?? 0)
            matchPopUp = popUp
            leading.append(popUp)
        } else {
            matchPopUp = nil
        }
        stack.setViews(leading, in: .leading)
        stack.setViews([clearButton], in: .trailing)
    }

    private func makeTagButton(_ tag: ConnectionTag) -> NSButton {
        // A template glyph takes the selected content color on the button's accent fill.
        let glyph = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil) ?? NSImage()
        let button = NSButton(title: tag.name, image: glyph, target: self, action: #selector(removeTag(_:)))
        button.bezelStyle = .accessoryBar
        button.setButtonType(.pushOnPushOff)
        button.state = .on
        button.imagePosition = .imageLeading
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = String(localized: "Remove Filter")
        tagIdsByButton[ObjectIdentifier(button)] = tag.id
        return button
    }

    private func makeMatchPopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.bezelStyle = .accessoryBarAction
        for match in LibraryTagMatch.allCases {
            popUp.addItem(withTitle: WelcomeToolbarController.title(for: match))
            popUp.lastItem?.representedObject = match
        }
        popUp.target = self
        popUp.action = #selector(matchChanged(_:))
        popUp.setAccessibilityLabel(String(localized: "Match"))
        return popUp
    }

    @objc private func removeTag(_ sender: NSButton) {
        guard let tagId = tagIdsByButton[ObjectIdentifier(sender)] else { return }
        viewModel.setTagFilter(tagId, isOn: false)
    }

    @objc private func matchChanged(_ sender: NSPopUpButton) {
        guard let match = sender.selectedItem?.representedObject as? LibraryTagMatch else { return }
        viewModel.tagMatch = match
    }

    @objc private func clearTagFilters(_ sender: Any?) {
        viewModel.clearTagFilters()
    }
}

// Before macOS 26 a split item has no accessory slot, so the bar sits at the top of the list pane
// under the toolbar, with a separator, where Mail put its filter bar.
@MainActor
internal final class WelcomeListPaneController: NSViewController {
    private let content: NSViewController
    private var barContainer: NSView?
    private var contentTop: NSLayoutConstraint?

    internal init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeListPaneController does not support NSCoder init")
    }

    override internal func loadView() {
        let root = NSView()
        addChild(content)
        let contentView = content.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)
        let top = contentView.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            top,
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        contentTop = top
        view = root
    }

    internal func showBar(_ bar: NSView?) {
        barContainer?.removeFromSuperview()
        barContainer = nil
        contentTop?.isActive = false
        guard let bar else {
            contentTop = content.view.topAnchor.constraint(equalTo: view.topAnchor)
            contentTop?.isActive = true
            return
        }
        let separator = NSBox()
        separator.boxType = .separator
        let container = NSStackView(views: [bar, separator])
        container.orientation = .vertical
        container.spacing = 0
        container.alignment = .width
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        let top = content.view.topAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top,
        ])
        barContainer = container
        contentTop = top
    }
}
