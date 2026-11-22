import SwiftUI

struct SettingsSectionActions<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
    }
}
