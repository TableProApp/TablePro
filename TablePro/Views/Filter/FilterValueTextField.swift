//
//  FilterValueTextField.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

struct FilterValueTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusedId: UUID?
    let identity: UUID
    var placeholder: String = ""
    var completions: [String] = []
    var allowsMultiLine: Bool = false
    var onSubmit: () -> Void = {}

    static func suggestions(for input: String, in completions: [String]) -> [String] {
        guard !input.isEmpty else { return [] }
        let needle = input.lowercased()
        let matches = completions.filter { $0.lowercased().hasPrefix(needle) }
        if matches.count == 1, matches[0].lowercased() == needle {
            return []
        }
        return matches
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
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

        context.coordinator.textField = textField
        context.coordinator.text = $text
        context.coordinator.focusedId = $focusedId
        context.coordinator.identity = identity
        context.coordinator.completions = completions
        context.coordinator.onSubmit = onSubmit

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusedId = $focusedId
        context.coordinator.identity = identity
        context.coordinator.completions = completions
        context.coordinator.onSubmit = onSubmit
        context.coordinator.textField = textField

        textField.placeholderString = placeholder

        let fieldEditor = textField.currentEditor() as? NSTextView
        if fieldEditor?.hasMarkedText() != true,
           textField.stringValue != text {
            textField.stringValue = text
        }

        if focusedId == identity {
            let binding = $focusedId
            let pendingId = identity
            DispatchQueue.main.async {
                guard let window = textField.window,
                      binding.wrappedValue == pendingId else { return }
                if window.firstResponder !== textField.currentEditor() {
                    window.makeFirstResponder(textField)
                }
                binding.wrappedValue = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusedId: $focusedId,
            identity: identity,
            completions: completions,
            onSubmit: onSubmit
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusedId: Binding<UUID?>
        var identity: UUID
        var completions: [String]
        var onSubmit: () -> Void
        weak var textField: NSTextField?

        private let suggestionState = SuggestionState()
        private var suggestionPopover: NSPopover?
        private var keyMonitor: Any?

        init(
            text: Binding<String>,
            focusedId: Binding<UUID?>,
            identity: UUID,
            completions: [String],
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.focusedId = focusedId
            self.identity = identity
            self.completions = completions
            self.onSubmit = onSubmit
        }

        deinit {
            if let token = keyMonitor {
                NSEvent.removeMonitor(token)
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
                    acceptCurrentSelection(submitting: true)
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
            return false
        }

        private func updateSuggestions(for textField: NSTextField) {
            guard !completions.isEmpty else {
                dismissSuggestions()
                return
            }
            if let fieldEditor = textField.currentEditor() as? NSTextView,
               fieldEditor.hasMarkedText() {
                dismissSuggestions()
                return
            }
            let input = text.wrappedValue
            guard !input.isEmpty else {
                dismissSuggestions()
                return
            }
            let filtered = FilterValueTextField.suggestions(for: input, in: completions)
            guard !filtered.isEmpty else {
                dismissSuggestions()
                return
            }

            if suggestionPopover != nil {
                suggestionState.items = filtered
                suggestionState.selectedIndex = 0
                return
            }

            showPopover(for: textField, items: filtered)
        }

        private func showPopover(for textField: NSTextField, items: [String]) {
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
                    self?.commit(selection: selection, submitting: false)
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

                    switch nsEvent.semanticKeyCode {
                    case .downArrow:
                        self.moveSelection(by: 1)
                        return nil
                    case .upArrow:
                        self.moveSelection(by: -1)
                        return nil
                    case .return:
                        self.acceptCurrentSelection(submitting: true)
                        return nil
                    case .tab:
                        self.acceptCurrentSelection(submitting: false)
                        return nil
                    case .escape:
                        self.dismissSuggestions()
                        return nsEvent
                    default:
                        return nsEvent
                    }
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
            commit(selection: items[index], submitting: submitting)
        }

        private func commit(selection: String, submitting: Bool) {
            text.wrappedValue = selection
            textField?.stringValue = selection
            dismissSuggestions()
            if submitting {
                onSubmit()
            }
        }

        func dismissSuggestions() {
            removeKeyMonitor()
            suggestionPopover?.close()
            suggestionPopover = nil
        }
    }

    @MainActor
    private final class SuggestionState: ObservableObject {
        @Published var items: [String] = []
        @Published var selectedIndex: Int = 0
    }

    private struct SuggestionDropdownView: View {
        @ObservedObject var state: SuggestionState
        let onSelect: (String) -> Void

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                            Button {
                                onSelect(item)
                            } label: {
                                Text(item)
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
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: state.selectedIndex) { _, newIndex in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }
}
