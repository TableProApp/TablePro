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

    override public func loadView() { // swiftlint:disable:this prohibited_super_call
        /// macOS 13 raises out of `super.loadView()` for a controller with no nib. See
        /// `PlainControllerView`, which is what `super` builds on 14.
        if #available(macOS 14.0, *) {
            super.loadView()
        } else {
            view = PlainControllerView.make()
        }

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

    /// Asked before any link of any editor's chain, whichever of its views holds focus, for a key
    /// session the app holds open across a whole window, such as a Control-Tab still held down. A
    /// session with a monitor of its own would race this one, because AppKit runs same-mask local
    /// monitors in no defined order, and the editor's find field or Vim could take its Escape.
    /// Returning true claims the key.
    public static var precedingKeyDownClaim: (@MainActor (NSEvent) -> Bool)?

    func setUpKeyBindings(eventMonitor: inout Any?) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            return self.dispatchKeyDown(event)
        }
    }

    /// The editor's only key-down entry point.
    ///
    /// `NSEvent.addLocalMonitorForEvents` gives same-mask monitors no defined order, so anything
    /// that wants a key in this editor is consulted from here in a fixed order rather than
    /// installing a monitor of its own.
    func dispatchKeyDown(_ event: NSEvent) -> NSEvent? {
        guard view.window?.isKeyWindow == true else { return event }
        return claimKeyDown(
            event,
            textViewHasFocus: view.window?.firstResponder === textView,
            findPanelHasFocus: findPanelHoldsFocus
        )
    }

    /// The chain, with the two focus questions answered by the caller so a test can drive the order
    /// without a key window. Links, in order: the app-wide preceding claim, the app's coordinators,
    /// the completion list, the find panel, and the editor's own commands.
    func claimKeyDown(_ event: NSEvent, textViewHasFocus: Bool, findPanelHasFocus: Bool) -> NSEvent? {
        if let precedingClaim = Self.precedingKeyDownClaim, precedingClaim(event) { return nil }

        if textViewHasFocus {
            for coordinator in textCoordinators.values()
            where coordinator.textViewShouldClaimKeyDown(controller: self, event: event) == nil {
                return nil
            }
            if isShowingCompletions, SuggestionController.shared.handleKeyDown(event) == nil { return nil }
        }

        if let findViewController, findViewController.viewModel.isShowingFindPanel,
           textViewHasFocus || findPanelHasFocus,
           findViewController.findPanel.handleKeyDown(event) == nil {
            return nil
        }

        guard textViewHasFocus else { return event }
        return handleEvent(event: event)
    }

    /// Whether the find panel's own search field holds focus. A focused `NSTextField` puts the
    /// window's shared field editor in the responder chain, and that editor is a descendant of the
    /// field, so the view test covers both. Only the find panel reads this; every other link stays
    /// behind `textViewHasFocus` so a chord typed into the search field cannot edit the document.
    private var findPanelHoldsFocus: Bool {
        guard let panel = findViewController?.findPanel,
              let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: panel)
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

    /// Escape reaching here means no earlier link in ``claimKeyDown(_:textViewHasFocus:findPanelHasFocus:)``
    /// claimed it. Xcode opens code completion on Escape and this editor follows it.
    private func handleEscape(_ event: NSEvent) -> NSEvent? {
        handleShowCompletions(event)
    }

    /// Handles the tab key event.
    /// If the Shift key is pressed, it handles unindenting. If no modifier key is pressed, it checks if multiple lines
    /// are highlighted and handles indenting accordingly.
    ///
    /// A Tab chord that holds Control or Command is never an edit. Control-Tab moves focus or switches
    /// tabs and Command-Tab switches apps, so both pass on to the menu bar and the key-view loop
    /// instead of indenting a multi-line selection.
    ///
    /// - Returns: The original event if it should be passed on, or `nil` to indicate handling within the method.
    func handleTab(event: NSEvent, modifierFlags: UInt) -> NSEvent? {
        let shiftKey = NSEvent.ModifierFlags.shift.rawValue
        let chordKeys = NSEvent.ModifierFlags([.control, .command]).rawValue

        guard modifierFlags & chordKeys == 0 else { return event }
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
