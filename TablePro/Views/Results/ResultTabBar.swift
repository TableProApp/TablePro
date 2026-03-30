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
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func resultTab(_ rs: ResultSet) -> some View {
        let isActive = rs.id == (activeResultSetId ?? resultSets.last?.id)
        return HStack(spacing: 4) {
            if rs.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Text(rs.label)
                .font(.system(size: 11))
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
        .padding(.vertical, 4)
        .background(isActive ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { activeResultSetId = rs.id }
        .contextMenu {
            Button(rs.isPinned ? "Unpin" : "Pin Result") { onPin?(rs.id) }
            Divider()
            Button("Close") { onClose?(rs.id) }
                .disabled(rs.isPinned)
            Button("Close Others") {
                for other in resultSets where other.id != rs.id && !other.isPinned {
                    onClose?(other.id)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var activeId: UUID?
    let sets = [
        ResultSet(label: "Result 1", rowsAffected: 10),
        ResultSet(label: "Result 2", rowsAffected: 5),
        ResultSet(label: "Result 3", isPinned: true)
    ]
    ResultTabBar(
        resultSets: sets,
        activeResultSetId: $activeId,
        onClose: { _ in },
        onPin: { _ in }
    )
    .frame(width: 500)
}
