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
