import AppKit
import Security
import SwiftUI

struct SecurePasswordField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

enum GeneratedPassword {
    static func suggest() -> String {
        if let suggestion = SecCreateSharedWebCredentialPassword() as String? {
            return suggestion
        }
        return random(length: 20)
    }

    static func random(length: Int) -> String {
        let alphabet = Array("abcdefghkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ3456789")
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess else {
            return String((0 ..< length).compactMap { _ in alphabet.randomElement() })
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
