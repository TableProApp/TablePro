import SwiftUI
import TableProPluginKit

struct AWSProfileField: View {
    let placeholder: String
    var accessibilityIdentifier: String?
    @Binding var value: String

    var body: some View {
        SuggestionComboBox(
            suggestions: Self.discoveredProfiles,
            placeholder: placeholder,
            controlSize: .small,
            accessibilityIdentifier: accessibilityIdentifier,
            value: $value
        )
    }

    private static func discoveredProfiles() -> [String] {
        AWSConfigFile.discoverProfiles(
            configContents: AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath),
            credentialsContents: AWSConfigFile.readFile(AWSConfigFile.defaultCredentialsPath)
        )
    }
}
