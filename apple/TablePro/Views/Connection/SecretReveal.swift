import Combine
import SwiftUI

@MainActor
final class SecretReveal: ObservableObject {
    @Published private(set) var isRevealed = false

    private let authenticator: any OperationAuthenticating
    private var hasAuthenticated = false
    private var isAuthenticating = false

    // LAContext shows this as "TablePro is trying to <reason>.", so it stays a lowercase phrase with no period.
    static var authenticationReason: String {
        String(localized: "show a saved password")
    }

    init(authenticator: any OperationAuthenticating = BiometricOperationAuthenticating()) {
        self.authenticator = authenticator
    }

    func setRevealed(_ reveal: Bool, requiresAuthentication: Bool) async {
        guard reveal else {
            isRevealed = false
            return
        }
        guard !isRevealed, !isAuthenticating else { return }
        if requiresAuthentication, !hasAuthenticated {
            isAuthenticating = true
            let granted = await authenticator.authenticate(reason: Self.authenticationReason)
            isAuthenticating = false
            guard granted else { return }
            hasAuthenticated = true
        }
        isRevealed = true
    }
}

struct SecretRevealToggle: View {
    @ObservedObject var reveal: SecretReveal
    let requiresAuthentication: Bool
    var title = String(localized: "Show password")

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { reveal.isRevealed },
            set: { newValue in
                Task { await reveal.setRevealed(newValue, requiresAuthentication: requiresAuthentication) }
            }
        ))
    }
}

// NSSecureTextField has no reveal of its own, so revealing swaps in a plain field, as the system's password fields do.
struct RevealablePasswordField: View {
    let title: String
    let subtitle: String?
    @Binding var text: String
    let requiresAuthentication: Bool
    let revealTitle: String

    @StateObject private var reveal = SecretReveal()

    init(
        title: String,
        subtitle: String? = nil,
        text: Binding<String>,
        requiresAuthentication: Bool,
        revealTitle: String = String(localized: "Show password")
    ) {
        self.title = title
        self.subtitle = subtitle
        self._text = text
        self.requiresAuthentication = requiresAuthentication
        self.revealTitle = revealTitle
    }

    var body: some View {
        if reveal.isRevealed {
            TextField(text: $text) { label }
                .autocorrectionDisabled()
        } else {
            SecureField(text: $text) { label }
        }
        SecretRevealToggle(reveal: reveal, requiresAuthentication: requiresAuthentication, title: revealTitle)
    }

    @ViewBuilder private var label: some View {
        Text(verbatim: title)
        if let subtitle {
            Text(verbatim: subtitle)
        }
    }
}
