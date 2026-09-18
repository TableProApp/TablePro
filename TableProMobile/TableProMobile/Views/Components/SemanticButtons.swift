import SwiftUI

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(String(localized: "Done"), action: action)
        }
    }
}

struct CancelButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .cancel, action: action)
        } else {
            Button("Cancel", role: .cancel, action: action)
        }
    }
}

struct DiscardChangesCancelButton: View {
    let hasChanges: Bool
    let discard: () -> Void

    @State private var isConfirmingDiscard = false

    var body: some View {
        CancelButton {
            guard hasChanges else {
                discard()
                return
            }
            isConfirmingDiscard = true
        }
        .discardChangesDialog(isPresented: $isConfirmingDiscard, discard: discard)
    }
}

struct DiscardChangesButton<Label: View>: View {
    let hasChanges: Bool
    let discard: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isConfirmingDiscard = false

    var body: some View {
        Button {
            guard hasChanges else {
                discard()
                return
            }
            isConfirmingDiscard = true
        } label: {
            label()
        }
        .discardChangesDialog(isPresented: $isConfirmingDiscard, discard: discard)
    }
}

extension View {
    func discardChangesDialog(isPresented: Binding<Bool>, discard: @escaping () -> Void) -> some View {
        confirmationDialog("Discard Changes?", isPresented: isPresented, titleVisibility: .hidden) {
            Button("Discard Changes", role: .destructive, action: discard)
            Button("Keep Editing", role: .cancel) {}
        }
    }
}

struct ConfirmButton: View {
    let title: LocalizedStringKey
    var isInProgress = false
    let action: () -> Void

    var body: some View {
        if isInProgress {
            ProgressView()
                .controlSize(.small)
        } else if #available(iOS 26.0, *) {
            Button(role: .confirm, action: action)
        } else {
            Button(title, action: action)
        }
    }
}
