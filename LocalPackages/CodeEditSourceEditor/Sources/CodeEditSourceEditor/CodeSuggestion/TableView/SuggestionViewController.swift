//
//  SuggestionViewController.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit
import SwiftUI
import Combine

class SuggestionViewController: NSViewController {
    var tintView: NSView = NSView()
    var tableView: NSTableView = NSTableView()
    var scrollView: NSScrollView = NSScrollView()
    var noItemsLabel: NSTextField = NSTextField(labelWithString: "No Completions")
    var previewView: CodeSuggestionPreviewView = CodeSuggestionPreviewView()

    var scrollViewHeightConstraint: NSLayoutConstraint?
    var viewHeightConstraint: NSLayoutConstraint?
    var viewWidthConstraint: NSLayoutConstraint?

    var itemObserver: AnyCancellable?
    var cachedFont: NSFont?

    weak var model: SuggestionViewModel? {
        didSet {
            itemObserver?.cancel()
            itemObserver = model?.$items.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.onItemsUpdated()
            }
        }
    }

    /// An event monitor for keyboard events
    private var localEventMonitor: Any?

    weak var windowController: SuggestionController?

    override func loadView() {
        super.loadView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8.5
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = 8.5
        tintView.layer?.backgroundColor = .clear
        view.addSubview(tintView)

        configureTableView()
        configureScrollView()

        noItemsLabel.textColor = .secondaryLabelColor
        noItemsLabel.alignment = .center
        noItemsLabel.translatesAutoresizingMaskIntoConstraints = false
        noItemsLabel.isHidden = false

        previewView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(noItemsLabel)
        view.addSubview(scrollView)
        view.addSubview(previewView)

        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: view.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            noItemsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noItemsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            noItemsLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: previewView.topAnchor),

            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        resetScrollPosition()
        tableView.reloadData()
        if let controller = model?.activeTextView {
            styleView(using: controller)
        }
        setupEventMonitors()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func setupEventMonitors() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self = self else { return event }

            switch event.type {
            case .keyDown:
                return checkKeyDownEvents(event)
            default:
                return event
            }
        }
    }

    private func checkKeyDownEvents(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // Escape
            windowController?.close()
            return nil

        case 125, 126:  // Down/Up Arrow
            tableView.keyDown(with: event)
            return nil

        case 36, 48:  // Return/Tab
            self.applySelectedItem()
            return nil

        default:
            return event
        }
    }

    func styleView(using controller: TextViewController) {
        noItemsLabel.font = controller.font
        previewView.font = controller.font
        previewView.documentationFont = controller.font
        switch controller.systemAppearance {
        case .aqua:
            let color = controller.theme.background
            if color != .clear {
                let newColor = NSColor(
                    red: color.redComponent * 0.95,
                    green: color.greenComponent * 0.95,
                    blue: color.blueComponent * 0.95,
                    alpha: 1.0
                )
                tintView.layer?.backgroundColor = newColor.cgColor
            } else {
                tintView.layer?.backgroundColor = .clear
            }
        case .darkAqua:
            tintView.layer?.backgroundColor = controller.theme.background.cgColor
        default:
            return
        }
        updateSize(using: controller)
    }

    func updateSize(using controller: TextViewController?) {
        guard model?.items.isEmpty == false && tableView.numberOfRows > 0 else {
            let size = NSSize(width: 256, height: noItemsLabel.fittingSize.height + 20)
            preferredContentSize = size
            windowController?.updateWindowSize(newSize: size)
            return
        }

        if controller != nil {
            cachedFont = controller?.font
        }

        guard let rowView = tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
            return
        }

        let maxLength = min(
            (model?.items.reduce(0, { max($0, $1.label.count + ($1.detail?.count ?? 0)) }) ?? 16) + 4,
            64
        )
        let newWidth = max( // minimum width = 256px, horizontal item padding = 13px
            CGFloat(maxLength) * (controller?.font ?? cachedFont ?? NSFont.systemFont(ofSize: 12)).charWidth + 26,
            256
        )

        let rowHeight = rowView.fittingSize.height

        let numberOfVisibleRows = min(CGFloat(model?.items.count ?? 0), SuggestionController.MAX_VISIBLE_ROWS)
        previewView.setPreferredMaxLayoutWidth(width: newWidth)
        var newHeight = rowHeight * numberOfVisibleRows + SuggestionController.WINDOW_PADDING * 2

        viewHeightConstraint?.isActive = false
        viewWidthConstraint?.isActive = false
        scrollViewHeightConstraint?.isActive = false

        scrollViewHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: newHeight)
        newHeight += previewView.fittingSize.height
        viewHeightConstraint = view.heightAnchor.constraint(equalToConstant: newHeight)
        viewWidthConstraint = view.widthAnchor.constraint(equalToConstant: newWidth)

        viewHeightConstraint?.isActive = true
        viewWidthConstraint?.isActive = true
        scrollViewHeightConstraint?.isActive = true

        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let newSize = NSSize(width: newWidth, height: newHeight)
        preferredContentSize = newSize
        windowController?.updateWindowSize(newSize: newSize)
    }

    func configureTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = false
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true
        tableView.gridStyleMask = []
        tableView.target = self
        tableView.action = #selector(tableViewClicked(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemsCell"))
        tableView.addTableColumn(column)
    }

    func configureScrollView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = NoSlotScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentInsets = NSEdgeInsets(
            top: SuggestionController.WINDOW_PADDING,
            left: 0,
            bottom: SuggestionController.WINDOW_PADDING,
            right: 0
        )
    }

    func onItemsUpdated() {
        resetScrollPosition()
        if let model {
            noItemsLabel.isHidden = !model.items.isEmpty
            scrollView.isHidden = model.items.isEmpty
            previewView.isHidden = model.items.isEmpty
        }
        tableView.reloadData()
        if let activeTextView = model?.activeTextView {
            updateSize(using: activeTextView)
        }
    }

    @objc private func tableViewClicked(_ sender: Any?) {
        if NSApp.currentEvent?.clickCount == 2 {
            applySelectedItem()
        }
    }

    private func resetScrollPosition() {
        let clipView = scrollView.contentView

        // Scroll to the top of the content
        clipView.scroll(to: NSPoint(x: 0, y: -SuggestionController.WINDOW_PADDING))

        // Select the first item
        if model?.items.isEmpty == false {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func applySelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0, row < model?.items.count ?? 0 else {
            return
        }
        if let model {
            model.applySelectedItem(item: model.items[tableView.selectedRow], window: view.window)
        }
    }
}

extension SuggestionViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model?.items.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model = model,
              row >= 0, row < model.items.count,
              let textView = model.activeTextView else {
            return nil
        }
        return NSHostingView(
            rootView: CodeSuggestionLabelView(
                suggestion: model.items[row],
                labelColor: textView.theme.text.color,
                secondaryLabelColor: textView.theme.text.color.withAlphaComponent(0.5),
                font: textView.font
            )
        )
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CodeSuggestionRowView { [weak self] in
            self?.model?.activeTextView?.theme.background ?? NSColor.controlBackgroundColor
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Only allow selection through keyboard navigation or single clicks
        NSApp.currentEvent?.type != .leftMouseDragged
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        if let model {
            // Update our preview view
            let selectedItem = model.items[tableView.selectedRow]

            previewView.sourcePreview = model.syntaxHighlights(forIndex: tableView.selectedRow)
            previewView.documentation = selectedItem.documentation
            previewView.pathComponents = selectedItem.pathComponents ?? []
            previewView.targetRange = selectedItem.targetPosition
            previewView.hideIfEmpty()
            updateSize(using: nil)

            model.didSelect(item: selectedItem)
        }
    }
}
