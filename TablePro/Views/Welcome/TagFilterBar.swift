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
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// `ButtonToggleStyle` reports the on and off value itself, and brings hover, press and the
    /// keyboard focus ring that a plain button with a hand-drawn capsule never had.
    ///
    /// The tint stays at the accent colour. Routing the tag's own colour through it turned the
    /// on-state from a prominent fill with a legible label into a wash of the tag colour with the
    /// label drawn in that same colour, which measured 1.37:1 on yellow. A tint is the accent for
    /// a control's selected state, not a decorative fill; the tag's colour belongs in the dot.
    private func tagPill(_ tag: ConnectionTag) -> some View {
        Toggle(isOn: binding(for: tag)) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tag.color.color)
                    .frame(width: 8, height: 8)
                Text(tag.name)
                    .font(.caption)
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(Text(tag.name))
    }

    private func binding(for tag: ConnectionTag) -> Binding<Bool> {
        Binding(
            get: { tagFilter.selectedIds.contains(tag.id) },
            set: { isOn in
                if isOn {
                    tagFilter.selectedIds.insert(tag.id)
                } else {
                    tagFilter.selectedIds.remove(tag.id)
                }
            }
        )
    }
}
