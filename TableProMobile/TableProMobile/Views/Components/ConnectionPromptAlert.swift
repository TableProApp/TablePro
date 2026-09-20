import SwiftUI
import TableProDatabase

/// Presents the attempt's questions from the screen that owns it. Attaching this at the root of the
/// window instead makes SwiftUI dismiss whatever that root is presenting, which is what took the
/// connection screen away and answered the host key question without the user.
struct ConnectionPromptAlert: ViewModifier {
    @Bindable var queue: ConnectionPromptQueue

    func body(content: Content) -> some View {
        content.alert(
            queue.current?.title ?? "",
            isPresented: Binding(
                get: { queue.current != nil },
                set: { presenting in
                    guard !presenting, let prompt = queue.current else { return }
                    queue.answer(prompt.id, accepted: false)
                }
            ),
            presenting: queue.current
        ) { prompt in
            Button(prompt.confirmTitle, role: buttonRole(for: prompt)) {
                queue.answer(prompt.id, accepted: true)
            }
            if prompt.style != .notice {
                Button(String(localized: "Cancel"), role: .cancel) {
                    queue.answer(prompt.id, accepted: false)
                }
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private func buttonRole(for prompt: ConnectionPrompt) -> ButtonRole? {
        switch prompt.style {
        case .destructive: .destructive
        case .notice: .cancel
        case .standard: nil
        }
    }
}

extension View {
    func connectionPrompts(_ queue: ConnectionPromptQueue) -> some View {
        modifier(ConnectionPromptAlert(queue: queue))
    }
}
