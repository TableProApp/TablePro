import SwiftUI

struct LibraryWriteFailureAlert: ViewModifier {
    let failure: LibraryWriteFailure?
    let onDismiss: () -> Void
    let closeForm: () -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { if !$0 { onDismiss() } }
        )
    }

    func body(content: Content) -> some View {
        content.alert(failure?.title ?? "", isPresented: isPresented, presenting: failure) { presented in
            Button("OK", role: .cancel) {
                guard presented.closesForm else { return }
                closeForm()
            }
        } message: { presented in
            Text(presented.message)
        }
    }
}

extension View {
    func libraryWriteFailureAlert(
        _ failure: LibraryWriteFailure?,
        onDismiss: @escaping () -> Void,
        closeForm: @escaping () -> Void
    ) -> some View {
        modifier(LibraryWriteFailureAlert(failure: failure, onDismiss: onDismiss, closeForm: closeForm))
    }
}
