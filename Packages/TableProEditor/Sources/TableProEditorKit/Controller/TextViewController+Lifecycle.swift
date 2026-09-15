//
//  TextViewController+LoadView.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 10/14/23.
//

import AppKit
import TableProTextEngine

extension TextViewController {
    override public func viewWillAppear() {
        super.viewWillAppear()
        // The calculation this causes cannot be done until the view knows it's final position
        updateFloatingSubviewInsets()
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        textCoordinators.forEach { $0.val?.controllerDidAppear(controller: self) }
    }

    override public func viewDidDisappear() {
        super.viewDidDisappear()
        textCoordinators.forEach { $0.val?.controllerDidDisappear(controller: self) }
    }

    override public func loadView() {
        /// Not `super.loadView()`. With a nil `nibName`, macOS 13 looks for a nib named after the
        /// class and raises when there is none; macOS 14 quietly makes an empty view instead.
        /// This controller has no nib on either, so it makes the view itself.
        view = NSView()

        scrollView = SourceEditorScrollView()
        scrollView.documentView = textView

        gutterView = GutterView(
            configuration: configuration,
            controller: self,
            delegate: self
        )
        gutterView.updateWidthIfNeeded()
        scrollView.addFloatingSubview(gutterView, for: .horizontal)

        let findViewController = FindViewController(target: self, childView: scrollView)
        addChild(findViewController)
        self.findViewController = findViewController
        self.view.addSubview(findViewController.view)
        findViewController.view.viewDidMoveToSuperview()
        self.findViewController = findViewController

        if let editorUndoManager {
            textView.setUndoManager(editorUndoManager)
        }

        styleTextView()
        styleScrollView()

        setUpHighlighter()
        setUpTextFormation()

        if !cursorPositions.isEmpty {
            setCursorPositions(cursorPositions)
        }

        setUpConstraints()
        setUpOberservers()

        textView.updateFrameIfNeeded()

        if let localEventMonitor = self.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        setUpKeyBindings(eventMonitor: &self.localEventMonitor)
        updateContentInsets()

        configuration.didSetOnController(controller: self, oldConfig: nil)
    }

    func setUpConstraints() {
        guard let findViewController else { return }

        NSLayoutConstraint.activate([
            findViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            findViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            findViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func setUpOnScrollChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.gutterView.needsDisplay = true
            NotificationCenter.default.post(name: Self.scrollPositionDidUpdateNotification, object: self)
        }
    }

    func setUpOnScrollViewFrameChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.gutterView.needsDisplay = true
            self?.emphasisManager?.removeEmphases(for: EmphasisGroup.brackets)
            self?.updateFloatingSubviewInsets()
            NotificationCenter.default.post(name: Self.scrollPositionDidUpdateNotification, object: self)
        }
    }

    func setUpTextViewFrameChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.gutterView.frame.size.height = self.textView.frame.height + 10
            self.gutterView.frame.origin.y = self.textView.frame.origin.y - self.scrollView.contentInsets.top
            self.gutterView.needsDisplay = true
            self.gutterView.foldingRibbon.needsDisplay = true
            self.scrollView.needsLayout = true
        }
    }

    func setUpSelectionChangedObserver() {
        NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView.selectionManager,
            queue: .main
        ) { [weak self] _ in
            self?.updateCursorPosition()
            self?.emphasizeSelectionPairs()
        }
    }

    func setUpAppearanceChangedObserver() {
        NSApp.publisher(for: \.effectiveAppearance)
            .receive(on: RunLoop.main)
            .sink { [weak self] newValue in
                guard let self = self else { return }

                if self.systemAppearance != newValue.name {
                    self.systemAppearance = newValue.name

                    // Reset content insets and gutter position when appearance changes
                    self.styleScrollView()
                    self.gutterView.frame.origin.y = self.textView.frame.origin.y - self.scrollView.contentInsets.top
                }
            }
            .store(in: &cancellables)
    }

    func setUpOberservers() {
        setUpOnScrollChangeObserver()
        setUpOnScrollViewFrameChangeObserver()
        setUpTextViewFrameChangeObserver()
        setUpSelectionChangedObserver()
        setUpAppearanceChangedObserver()
    }

    func setUpKeyBindings(eventMonitor: inout Any?) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event -> NSEvent? in
            guard let self = self else { return event }

            // Check if this window is key and if the text view is the first responder
            let isKeyWindow = self.view.window?.isKeyWindow ?? false
            let isFirstResponder = self.view.window?.firstResponder === self.textView

            // Only handle commands if this is the key window and text view is first responder
            guard isKeyWindow && isFirstResponder else { return event }
            return handleEvent(event: event)
        }
    }

    func handleEvent(event: NSEvent) -> NSEvent? {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
        switch event.type {
        case .keyDown:
            guard !textView.hasMarkedText() else {
                return handleKeyDownDuringComposition(event: event, modifierFlags: modifierFlags)
            }
            let tabKey: UInt16 = 0x30

            if event.keyCode == tabKey {
                return self.handleTab(event: event, modifierFlags: modifierFlags.rawValue)
            } else {
                return self.handleCommand(event: event, modifierFlags: modifierFlags)
            }
        default:
            return event
        }
    }

    private func handleKeyDownDuringComposition(event: NSEvent, modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
        guard let command = EditorKeyCommand(event: event, modifierFlags: modifierFlags),
              command.isCommandChord else {
            return event
        }
        return nil
    }

    func handleCommand(event: NSEvent, modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
        guard let command = EditorKeyCommand(event: event, modifierFlags: modifierFlags) else { return event }

        switch command {
        case .toggleComment:
            handleCommandSlash()
        case .outdent:
            handleIndent(inwards: true)
        case .indent:
            handleIndent()
        case .duplicateLine:
            duplicateLine()
        case .deleteLine:
            deleteLine()
        case .moveLinesUp:
            moveLinesUp()
        case .moveLinesDown:
            moveLinesDown()
        case .escape:
            return handleEscape(event)
        case .showCompletions:
            return handleShowCompletions(event)
        }
        return nil
    }

    private func handleEscape(_ event: NSEvent) -> NSEvent? {
        guard let findViewController, findViewController.viewModel.isShowingFindPanel else {
            return handleShowCompletions(event)
        }
        findViewController.hideFindPanel()
        return nil
    }

    /// Handles the tab key event.
    /// If the Shift key is pressed, it handles unindenting. If no modifier key is pressed, it checks if multiple lines
    /// are highlighted and handles indenting accordingly.
    ///
    /// - Returns: The original event if it should be passed on, or `nil` to indicate handling within the method.
    func handleTab(event: NSEvent, modifierFlags: UInt) -> NSEvent? {
        let shiftKey = NSEvent.ModifierFlags.shift.rawValue

        if modifierFlags == shiftKey {
            handleIndent(inwards: true)
        } else {
            // Only allow tab to work if multiple lines are selected
            guard multipleLinesHighlighted() else { return event }
            handleIndent()
        }
        return nil
    }

    private func handleShowCompletions(_ event: NSEvent) -> NSEvent? {
        guard let completionDelegate = self.completionDelegate,
              let cursorPosition = cursorPositions.first else {
            return event
        }
        if dismissCompletions() {
            return nil
        }
        SuggestionController.shared.showCompletions(
            textView: self,
            delegate: completionDelegate,
            cursorPosition: cursorPosition,
            isManualTrigger: true
        )
        return nil
    }
}
