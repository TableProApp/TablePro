import SwiftUI

struct TagFilterBar: View {
    @Binding var tagFilter: TagFilter
    let availableTags: [ConnectionTag]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if tagFilter.selectedIds.count > 1 {
                    matchModeMenu
                }
                ForEach(availableTags) { tag in
                    tagPill(tag)
                }
                if tagFilter.isActive {
                    Button(String(localized: "Clear")) {
                        tagFilter.selectedIds.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var matchModeMenu: some View {
        Menu {
            Button(String(localized: "Match Any")) { tagFilter.mode = .any }
            Button(String(localized: "Match All")) { tagFilter.mode = .all }
        } label: {
            Text(tagFilter.mode == .any ? String(localized: "Match Any") : String(localized: "Match All"))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func tagPill(_ tag: ConnectionTag) -> some View {
        let selected = tagFilter.selectedIds.contains(tag.id)
        return Button {
            if selected {
                tagFilter.selectedIds.remove(tag.id)
            } else {
                tagFilter.selectedIds.insert(tag.id)
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(tag.color.color)
                    .frame(width: 8, height: 8)
                Text(tag.name)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .background(selected ? tag.color.color.opacity(0.18) : Color.clear, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                selected ? tag.color.color : Color.secondary.opacity(0.3),
                lineWidth: 1
            )
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
