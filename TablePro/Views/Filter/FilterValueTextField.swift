//
//  FilterValueTextField.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

enum FilterCompletionSource {
    case staticValues([String])
    case sqlTokens(RawSQLFilterCompletionProvider)
}

struct FilterFocusState: Equatable {
    private(set) var claimedId: UUID?

    mutating func claimFocus(requestedId: UUID?, identity: UUID) -> Bool {
        guard requestedId == identity, claimedId != identity else { return false }
        claimedId = identity
        return true
    }

    mutating func markFocused(_ identity: UUID) {
        claimedId = identity
    }

    mutating func releaseFocus() {
        claimedId = nil
    }
}

struct FilterValueTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusedId: UUID?
    let identity: UUID
    var placeholder: String = ""
    var completionSource: FilterCompletionSource = .staticValues([])
    var allowsMultiLine: Bool = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    static func suggestions(for input: String, in completions: [String]) -> [String] {
        guard !input.isEmpty else { return [] }
        let needle = input.lowercased()
        let matches = completions.filter { $0.lowercased().hasPrefix(needle) }
        if matches.count == 1, matches[0].lowercased() == needle {
            return []
        }
        return matches
    }

    static func splice(into current: String, range: NSRange, insertText: String) -> (text: String, caret: Int)? {
        let ns = current as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        let caret = range.location + (insertText as NSString).length
        return (ns.replacingCharacters(in: range, with: insertText), caret)
    }

    enum SuggestionKeyOutcome: Equatable {
        case moveSelection(Int)
        case accept(submitting: Bool)
        case dismiss
        case passThrough
    }

    static func suggestionKeyOutcome(for key: KeyCode?, submitsOnAccept: Bool) -> SuggestionKeyOutcome {
        switch key {
        case .downArrow: return .moveSelection(1)
        case .upArrow: return .moveSelection(-1)
        case .return: return .accept(submitting: submitsOnAccept)
        case .tab: return .accept(submitting: false)
        case .escape: return .dismiss
        default: return .passThrough
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = SubstitutionDisabledTextField()
        textField.bezelStyle = .roundedBezel
        textField.controlSize = .small
        textField.font = .systemFont(ofSize: 12)
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.stringValue = text

        if allowsMultiLine {
            textField.usesSingleLineMode = false
            textField.cell?.wraps = true
            textField.cell?.isScrollable = false
            textField.lineBreakMode = .byWordWrapping
            textField.maximumNumberOfLines = 0
        } else {
            textField.lineBreakMode = .byTruncatingTail
        }

        textField.owner = context.coordinator
        context.coordinator.textField = textField
        context.coordinator.text = $text
        context.coordinator.focusedId = $focusedId
        context.coordinator.identity = identity
        context.coordinator.completionSource = completionSource
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusedId = $focusedId
        context.coordinator.identity = identity
        context.coordinator.completionSource = completionSource
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        context.coordinator.textField = textField

        textField.placeholderString = placeholder

        let fieldEditor = textField.currentEditor() as? NSTextView
        if fieldEditor?.hasMarkedText() != true,
           textField.stringValue != text {
            textField.stringValue = text
        }

        context.coordinator.focusIfRequested()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusedId: $focusedId,
            identity: identity,
            completionSource: completionSource,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusedId: Binding<UUID?>
        var identity: UUID
        var completionSource: FilterCompletionSource
        var onSubmit: () -> Void
        var onCancel: () -> Void
        weak var textField: NSTextField?

        private let suggestionState = SuggestionState()
        private var suggestionPopover: NSPopover?
        private var keyMonitor: Any?
        private var focusState = FilterFocusState()
        private var windowKeyObserver: NSObjectProtocol?
        private var latestReplacementRange: NSRange?
        private var completionGeneration = 0
        private static let completionDebounce: UInt64 = 50_000_000

        private var submitsOnAccept: Bool {
            if case .staticValues = completionSource { return true }
            return false
        }

        init(
            text: Binding<String>,
            focusedId: Binding<UUID?>,
            identity: UUID,
            completionSource: FilterCompletionSource,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.focusedId = focusedId
            self.identity = identity
            self.completionSource = completionSource
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func focusIfRequested() {
            guard let textField,
                  let window = textField.window,
                  focusState.claimFocus(requestedId: focusedId.wrappedValue, identity: identity) else { return }
            if window.firstResponder !== textField.currentEditor() {
                window.makeFirstResponder(textField)
            }
        }

        func handleBecameFirstResponder() {
            focusState.markFocused(identity)
            if focusedId.wrappedValue != identity {
                focusedId.wrappedValue = identity
            }
        }

        func handleResignedFirstResponder() {
            focusState.releaseFocus()
            if focusedId.wrappedValue == identity {
                focusedId.wrappedValue = nil
            }
        }

        func startObservingWindowKeyStatus(for window: NSWindow) {
            stopObservingWindowKeyStatus()
            windowKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleResignedFirstResponder()
                }
            }
        }

        func stopObservingWindowKeyStatus() {
            guard let token = windowKeyObserver else { return }
            NotificationCenter.default.removeObserver(token)
            windowKeyObserver = nil
        }

        deinit {
            if let token = keyMonitor {
                NSEvent.removeMonitor(token)
            }
            if let token = windowKeyObserver {
                NotificationCenter.default.removeObserver(token)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
            updateSuggestions(for: textField)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            dismissSuggestions()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if suggestionPopover != nil {
                    acceptCurrentSelection(submitting: submitsOnAccept)
                    return true
                }
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                text.wrappedValue = textView.string
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if suggestionPopover != nil {
                    dismissSuggestions()
                    return true
                }
                onCancel()
                return true
            }
            return false
        }

        private func updateSuggestions(for textField: NSTextField) {
            if let fieldEditor = textField.currentEditor() as? NSTextView,
               fieldEditor.hasMarkedText() {
                dismissSuggestions()
                return
            }
            switch completionSource {
            case .staticValues(let values):
                updateStaticSuggestions(for: textField, values: values)
            case .sqlTokens(let provider):
                updateTokenSuggestions(for: textField, provider: provider)
            }
        }

        private func updateStaticSuggestions(for textField: NSTextField, values: [String]) {
            guard !values.isEmpty else {
                dismissSuggestions()
                return
            }
            let input = text.wrappedValue
            guard !input.isEmpty else {
                dismissSuggestions()
                return
            }
            let filtered = FilterValueTextField.suggestions(for: input, in: values)
            guard !filtered.isEmpty else {
                dismissSuggestions()
                return
            }
            let items = filtered.map { SuggestionItem(label: $0, insertText: $0) }
            presentSuggestions(items, for: textField, replacementRange: nil)
        }

        private func updateTokenSuggestions(for textField: NSTextField, provider: RawSQLFilterCompletionProvider) {
            let fieldText = textField.stringValue
            guard !fieldText.isEmpty else {
                dismissSuggestions()
                return
            }
            let editor = textField.currentEditor() as? NSTextView
            let cursor = editor?.selectedRange().location ?? (fieldText as NSString).length

            completionGeneration &+= 1
            let generation = completionGeneration
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.completionDebounce)
                guard let self, self.completionGeneration == generation else { return }
                let result = await provider.completions(fieldText: fieldText, cursor: cursor)
                guard self.completionGeneration == generation else { return }
                guard let result else {
                    self.dismissSuggestions()
                    return
                }
                let items = result.items.map {
                    SuggestionItem(label: $0.label, insertText: $0.insertText)
                }
                self.presentSuggestions(items, for: textField, replacementRange: result.replacementRange)
            }
        }

        private func presentSuggestions(
            _ items: [SuggestionItem],
            for textField: NSTextField,
            replacementRange: NSRange?
        ) {
            latestReplacementRange = replacementRange
            if suggestionPopover != nil {
                suggestionState.items = items
                suggestionState.selectedIndex = 0
                return
            }
            showPopover(for: textField, items: items)
        }

        private func showPopover(for textField: NSTextField, items: [SuggestionItem]) {
            suggestionState.items = items
            suggestionState.selectedIndex = 0

            let bounds = textField.bounds
            let state = suggestionState
            let dropdownWidth = max(textField.bounds.width, 160)
            let rowHeight: CGFloat = 22
            let visibleRows = min(items.count, 8)
            let dropdownHeight = CGFloat(visibleRows) * rowHeight + 8

            let popover = PopoverPresenter.show(
                relativeTo: bounds,
                of: textField,
                preferredEdge: .maxY,
                contentSize: NSSize(width: dropdownWidth, height: dropdownHeight)
            ) { [weak self] dismiss in
                SuggestionDropdownView(state: state) { selection in
                    self?.commit(item: selection, submitting: false)
                    dismiss()
                }
            }
            suggestionPopover = popover
            installKeyMonitor()
        }

        private func installKeyMonitor() {
            removeKeyMonitor()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let nsEvent = event
                return MainActor.assumeIsolated {
                    guard let self,
                          self.suggestionPopover != nil,
                          let textField = self.textField,
                          nsEvent.window === textField.window,
                          nsEvent.window?.firstResponder === textField.currentEditor()
                    else { return nsEvent }

                    switch FilterValueTextField.suggestionKeyOutcome(
                        for: nsEvent.semanticKeyCode,
                        submitsOnAccept: self.submitsOnAccept
                    ) {
                    case .moveSelection(let delta):
                        self.moveSelection(by: delta)
                    case .accept(let submitting):
                        self.acceptCurrentSelection(submitting: submitting)
                    case .dismiss:
                        self.dismissSuggestions()
                    case .passThrough:
                        return nsEvent
                    }
                    return nil
                }
            }
        }

        private func removeKeyMonitor() {
            if let token = keyMonitor {
                NSEvent.removeMonitor(token)
                keyMonitor = nil
            }
        }

        private func moveSelection(by delta: Int) {
            let count = suggestionState.items.count
            guard count > 0 else { return }
            let next = suggestionState.selectedIndex + delta
            suggestionState.selectedIndex = max(0, min(count - 1, next))
        }

        private func acceptCurrentSelection(submitting: Bool) {
            let items = suggestionState.items
            let index = suggestionState.selectedIndex
            guard index >= 0, index < items.count else {
                dismissSuggestions()
                if submitting { onSubmit() }
                return
            }
            commit(item: items[index], submitting: submitting)
        }

        private func commit(item: SuggestionItem, submitting: Bool) {
            switch completionSource {
            case .staticValues:
                text.wrappedValue = item.insertText
                textField?.stringValue = item.insertText
            case .sqlTokens:
                spliceTokenCompletion(item.insertText)
            }
            dismissSuggestions()
            if submitting {
                onSubmit()
            }
        }

        private func spliceTokenCompletion(_ insertText: String) {
            guard let textField, let range = latestReplacementRange,
                  let spliced = FilterValueTextField.splice(
                      into: textField.stringValue, range: range, insertText: insertText
                  )
            else { return }

            text.wrappedValue = spliced.text
            textField.stringValue = spliced.text
            (textField.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: spliced.caret, length: 0)
        }

        func dismissSuggestions() {
            completionGeneration &+= 1
            removeKeyMonitor()
            suggestionPopover?.close()
            suggestionPopover = nil
        }
    }

    private final class SubstitutionDisabledTextField: NSTextField {
        weak var owner: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                owner?.startObservingWindowKeyStatus(for: window)
            } else {
                owner?.stopObservingWindowKeyStatus()
            }
            owner?.focusIfRequested()
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result, let editor = currentEditor() as? NSTextView {
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
            }
            if result {
                owner?.handleBecameFirstResponder()
            }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                owner?.handleResignedFirstResponder()
            }
            return result
        }
    }

    private struct SuggestionItem: Equatable {
        let label: String
        let insertText: String
    }

    @MainActor
    private final class SuggestionState: ObservableObject {
        @Published var items: [SuggestionItem] = []
        @Published var selectedIndex: Int = 0
    }

    private struct SuggestionDropdownView: View {
        @ObservedObject var state: SuggestionState
        let onSelect: (SuggestionItem) -> Void

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                            Text(item.label)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    state.selectedIndex == index
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(item) }
                                .id(index)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(item.label)
                                .accessibilityAddTraits(
                                    state.selectedIndex == index ? [.isButton, .isSelected] : .isButton
                                )
                        }
                    }
                    .padding(4)
                }
                .focusable(false)
                .onChange(of: state.selectedIndex) { _, newIndex in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }
}
