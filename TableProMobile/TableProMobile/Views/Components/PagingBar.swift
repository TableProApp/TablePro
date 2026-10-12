import SwiftUI

struct PagingBar<Status: View>: View {
    let previousTitle: LocalizedStringResource
    let nextTitle: LocalizedStringResource
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder let status: Status

    var body: some View {
        HStack {
            step(previousTitle, systemImage: "chevron.backward", isEnabled: canGoPrevious, action: onPrevious)
            Spacer()
            status
            Spacer()
            step(nextTitle, systemImage: "chevron.forward", isEnabled: canGoNext, action: onNext)
        }
        .padding(.horizontal)
    }

    private func step(
        _ title: LocalizedStringResource,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .disabled(!isEnabled)
    }
}
