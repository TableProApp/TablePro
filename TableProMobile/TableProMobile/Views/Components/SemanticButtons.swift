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

struct ConfirmButton<Label: View>: View {
    private let action: () -> Void
    private let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .confirm, action: action)
        } else {
            Button(action: action) { label }
        }
    }
}
