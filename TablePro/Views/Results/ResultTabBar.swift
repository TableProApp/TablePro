//
//  ResultTabBar.swift
//  TablePro
//
//  Horizontal tab bar for switching between multiple result sets.
//  Only shown when a query produces 2+ result sets.
//

import SwiftUI

struct ResultTabBar: View {
    let resultSets: [ResultSet]
    @Binding var activeResultSetId: UUID?
    var onClose: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(resultSets) { rs in
                    resultTab(rs)
                }
            }
        }
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func resultTab(_ rs: ResultSet) -> some View {
        let isActive = rs.id == (activeResultSetId ?? resultSets.last?.id)
        return HStack(spacing: 4) {
            if rs.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(rs.label)
                .font(.subheadline)
                .lineLimit(1)
            if !rs.isPinned {
                Button { onClose?(rs.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color(nsColor: .selectedControlColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { activeResultSetId = rs.id }
        .contextMenu {
            Button(rs.isPinned ? String(localized: "Unpin") : String(localized: "Pin Result")) {
                onPin?(rs.id)
            }
            Divider()
            Button(String(localized: "Close")) { onClose?(rs.id) }
                .disabled(rs.isPinned)
            Button(String(localized: "Close Others")) {
                for other in resultSets where other.id != rs.id && !other.isPinned {
                    onClose?(other.id)
                }
            }
        }
    }
}
