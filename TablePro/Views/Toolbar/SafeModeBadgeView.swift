//
//  SafeModeBadgeView.swift
//  TablePro
//

import SwiftUI

struct SafeModeBadgeView: View {
    @Binding var safeModeLevel: SafeModeLevel
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: safeModeLevel.iconName)
                .fontWeight(.medium)
                .foregroundStyle(safeModeLevel.badgeColor)
        }
        .buttonStyle(.plain)
        .help(String(format: String(localized: "Safe Mode: %@"), safeModeLevel.displayName))
        .accessibilityLabel(String(format: String(localized: "Safe Mode: %@"), safeModeLevel.displayName))
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Safe Mode")
                    .font(.headline)
                    .padding(.bottom, 4)

                Picker("", selection: $safeModeLevel) {
                    ForEach(SafeModeLevel.allCases) { level in
                        Label(level.displayName, systemImage: level.iconName)
                            .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .padding()
            .frame(width: 220)
            .onExitCommand { showPopover = false }
        }
    }
}

// MARK: - Preview

#Preview("Safe Mode Badges") {
    VStack(spacing: 12) {
        SafeModeBadgeView(safeModeLevel: .constant(.silent))
        SafeModeBadgeView(safeModeLevel: .constant(.alert))
        SafeModeBadgeView(safeModeLevel: .constant(.safeMode))
        SafeModeBadgeView(safeModeLevel: .constant(.readOnly))
    }
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}
