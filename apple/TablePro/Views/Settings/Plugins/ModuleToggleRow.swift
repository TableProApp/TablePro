import SwiftUI

// This switch is the only way a module turns on (apple/AGENTS.md, Scope), and only module rows observe the settings.
struct ModuleToggleRow: View {
    let module: AppModule
    @ObservedObject private var settings: AppModuleSettings

    init(module: AppModule, settings: AppModuleSettings = .shared) {
        self.module = module
        self.settings = settings
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.isEnabled(module) },
            set: { AppModuleActivation.setEnabled($0, for: module, settings: settings) }
        )) {
            Text(verbatim: module.title)
            Text(verbatim: module.summary)
        }
        .accessibilityIdentifier("module-toggle-\(module.rawValue)")
    }
}
