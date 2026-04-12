import SwiftUI

struct RoutineRowView: View {
    let routine: RoutineInfo
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: routine.type == .function ? "function" : "gearshape.2")
                .font(.system(size: 12))
                .foregroundStyle(routine.type == .function ? .purple : .teal)
                .frame(width: 16)
            Text(routine.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 1)
        .foregroundStyle(isActive ? .primary : .secondary)
    }
}
