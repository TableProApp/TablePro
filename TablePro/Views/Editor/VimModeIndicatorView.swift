//
//  VimModeIndicatorView.swift
//  TablePro
//
//  Compact badge showing the current Vim editing mode
//

import SwiftUI

/// Compact badge displaying the current Vim editing mode in the editor toolbar
struct VimModeIndicatorView: View {
    let mode: VimMode

    var body: some View {
        if case .commandLine = mode {
            Text(mode.displayLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text(mode.displayLabel)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var foregroundColor: Color {
        switch mode {
        case .normal: return .secondary
        case .insert: return .emphasizedSelectionLabel
        case .replace, .visual, .commandLine: return .legibleForeground(on: backgroundColor)
        }
    }

    private var backgroundColor: Color {
        switch mode {
        case .normal: return Color(nsColor: .controlBackgroundColor)
        case .insert: return Color(nsColor: .selectedContentBackgroundColor)
        case .replace: return .red
        case .visual: return .orange
        case .commandLine: return .purple
        }
    }
}

#Preview {
    HStack {
        VimModeIndicatorView(mode: .normal)
        VimModeIndicatorView(mode: .insert)
        VimModeIndicatorView(mode: .visual(linewise: false))
        VimModeIndicatorView(mode: .visual(linewise: true))
        VimModeIndicatorView(mode: .commandLine(buffer: ":w"))
    }
    .padding()
}
