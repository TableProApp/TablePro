//
//  PanelStyles.swift
//  CodeEdit
//
//  Created by Austin Condiff on 3/12/25.
//

import SwiftUI

private struct InsideControlGroupKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isInsideControlGroup: Bool {
        get { self[InsideControlGroupKey.self] }
        set { self[InsideControlGroupKey.self] = newValue }
    }
}

struct PanelControlGroupStyle: ControlGroupStyle {
    @Environment(\.controlActiveState) private var controlActiveState

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.content
                .buttonStyle(PanelButtonStyle())
                .environment(\.isInsideControlGroup, true)
                .padding(.vertical, 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
        )
        .cornerRadius(4)
        .clipped()
    }
}

struct PanelButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isInsideControlGroup) private var isInsideControlGroup

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(Color(.controlTextColor))
            .padding(.horizontal, 6)
            .frame(height: isInsideControlGroup ? 16 : 18)
            .background(
                configuration.isPressed
                    ? colorScheme == .light
                        ? Color.black.opacity(0.06)
                        : Color.white.opacity(0.24)
                    : Color.clear
            )
            .overlay(
                Group {
                    if !isInsideControlGroup {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
                    }
                }
            )
            .cornerRadius(isInsideControlGroup ? 0 : 4)
            .clipped()
            .contentShape(Rectangle())
    }
}
