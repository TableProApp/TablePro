//
//  DataFileFindBar.swift
//  TablePro
//

import SwiftUI

struct DataFileFindBar: View {
    @ObservedObject var controller: DataFileController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            findRow
            if controller.find.isReplaceVisible, controller.isEditable {
                replaceRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: Binding(
                    get: { controller.find.text },
                    set: { newValue in
                        controller.find.text = newValue
                        controller.scheduleFind()
                    }
                ),
                placeholder: String(localized: "Find in file"),
                controlSize: .regular,
                onSubmit: { controller.findNext() },
                focusOnAppear: true,
                accessibilityIdentifier: "data-file-find-field"
            )
            .frame(maxWidth: 320)

            optionsMenu

            Text(counterText)
                .font(.callout)
                .foregroundStyle(controller.find.isPatternInvalid ? Color.red : Color.secondary)
                .monospacedDigit()
                .accessibilityLabel(counterText)

            HStack(spacing: 2) {
                Button(String(localized: "Previous match"), systemImage: "chevron.left") {
                    controller.findPrevious()
                }
                .help(String(localized: "Previous match"))
                Button(String(localized: "Next match"), systemImage: "chevron.right") {
                    controller.findNext()
                }
                .help(String(localized: "Next match"))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(controller.find.matches.isEmpty)

            if let scope = controller.find.scopeColumn, let name = controller.columnNames.name(for: scope) {
                Button {
                    controller.find.scopeColumn = nil
                    controller.runFind()
                } label: {
                    Label(String(format: String(localized: "In column %@"), name), systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Search every column"))
            }

            Spacer()

            if !controller.find.isReplaceVisible, controller.isEditable {
                Button(String(localized: "Replace…")) {
                    controller.find.isReplaceVisible = true
                }
                .buttonStyle(.borderless)
            }

            Button(String(localized: "Done")) {
                controller.hideFind()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Replace with"),
                text: Binding(get: { controller.find.replacement }, set: { controller.find.replacement = $0 })
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
            .accessibilityIdentifier("data-file-replace-field")

            Button(String(localized: "Replace")) {
                controller.replaceCurrent()
            }
            .disabled(controller.find.currentIndex == nil || controller.isBusy)

            Button(String(localized: "Replace All")) {
                controller.replaceAll()
            }
            .disabled(!controller.find.hasQuery || controller.find.isPatternInvalid || controller.isBusy)
            .accessibilityIdentifier("data-file-replace-all")

            Spacer()
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(String(localized: "Match Case"), isOn: option(\.matchesCase))
            Toggle(String(localized: "Whole Words"), isOn: option(\.matchesWholeWords))
            Toggle(String(localized: "Regular Expression"), isOn: option(\.isRegularExpression))
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Find Options"))
        .accessibilityLabel(String(localized: "Find Options"))
    }

    private func option(_ keyPath: WritableKeyPath<DataFileFindState, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.find[keyPath: keyPath] },
            set: { newValue in
                controller.find[keyPath: keyPath] = newValue
                controller.runFind()
            }
        )
    }

    private var counterText: String {
        guard controller.find.hasQuery else { return "" }
        if controller.find.isPatternInvalid {
            return String(localized: "Invalid regular expression")
        }
        if controller.find.isSearching {
            return String(localized: "Searching…")
        }
        guard let index = controller.find.currentIndex, !controller.find.matches.isEmpty else {
            return String(localized: "No matches")
        }
        return String(
            format: String(localized: "%@ of %@"),
            (index + 1).formatted(),
            controller.find.matches.count.formatted()
        )
    }
}
