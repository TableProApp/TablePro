import SwiftUI
import TableProDatabase

/// Presents the attempt's questions from the screen that owns it. Attaching this at the root of the
/// window instead makes SwiftUI dismiss whatever that root is presenting, which is what took the
/// connection screen away and answered the host key question without the user.
///
/// The question on screen is held here rather than read back from the queue, so a dismissal answers
/// the question the user was looking at and never the one waiting behind it.
struct ConnectionPromptAlert: ViewModifier {
    @Bindable var queue: ConnectionPromptQueue

    @State private var shown: ConnectionPrompt?

    func body(content: Content) -> some View {
        content
            .alert(
                shown?.title ?? "",
                isPresented: Binding(
                    get: { shown != nil },
                    set: { presenting in
                        guard !presenting, let prompt = shown else { return }
                        answer(prompt, accepted: false)
                    }
                ),
                presenting: shown
            ) { prompt in
                Button(prompt.confirmTitle, role: buttonRole(for: prompt)) {
                    answer(prompt, accepted: true)
                }
                if prompt.style != .notice {
                    Button(String(localized: "Cancel"), role: .cancel) {
                        answer(prompt, accepted: false)
                    }
                }
            } message: { prompt in
                Text(prompt.message)
            }
            .onChange(of: queue.current, initial: true) { _, next in
                shown = next
            }
    }

    private func answer(_ prompt: ConnectionPrompt, accepted: Bool) {
        shown = nil
        queue.answer(prompt.id, accepted: accepted)
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
