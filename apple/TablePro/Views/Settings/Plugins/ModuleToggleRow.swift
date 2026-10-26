import SwiftUI

// A checkbox per module, the way Safari lists its extensions; this click is the only way a module turns on.
struct ModuleToggleRow: View {
    let module: AppModule
    @ObservedObject var settings: AppModuleSettings

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.isEnabled(module) },
            set: { AppModuleActivation.setEnabled($0, for: module, settings: settings) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                Text(module.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
        .accessibilityIdentifier("module-toggle-\(module.rawValue)")
    }
}

extension AppModule {
    func matches(filter: String) -> Bool {
        filter.isEmpty
            || title.localizedCaseInsensitiveContains(filter)
            || summary.localizedCaseInsensitiveContains(filter)
    }
}
