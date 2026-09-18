import SwiftUI

struct AcknowledgementsView: View {
    @State private var inventory: Loadable<AcknowledgementsInventory> = .loading

    init() {}

    var body: some View {
        content
            .navigationTitle("Acknowledgements")
            .task { loadInventoryIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch inventory {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let loaded) where !loaded.components.isEmpty:
            componentList(loaded)
        case .loaded, .failed:
            ContentUnavailableView(
                "No License Information",
                systemImage: "doc.text.magnifyingglass",
                description: Text("The list of open source libraries is missing from this build.")
            )
        }
    }

    private func componentList(_ inventory: AcknowledgementsInventory) -> some View {
        List(inventory.components) { component in
            NavigationLink {
                AcknowledgementDetailView(component: component, inventory: inventory)
            } label: {
                AcknowledgementRow(component: component)
            }
        }
    }

    private func loadInventoryIfNeeded() {
        guard case .loading = inventory else { return }
        do {
            inventory = .loaded(try AcknowledgementsInventory.bundled())
        } catch {
            inventory = .failed(error)
        }
    }
}

private struct AcknowledgementRow: View {
    let component: AcknowledgementComponent

    var body: some View {
        LabeledContent {
            Text(verbatim: component.displayVersion)
                .lineLimit(1)
        } label: {
            Text(verbatim: component.name)
            Text(verbatim: component.spdx)
        }
    }
}

private struct AcknowledgementDetailView: View {
    let component: AcknowledgementComponent
    let inventory: AcknowledgementsInventory

    @State private var licenseText: Loadable<String> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Version") {
                    Text(verbatim: component.displayVersion)
                }
                LabeledContent("License") {
                    Text(verbatim: component.spdx)
                }
                if let homepage = component.homepage {
                    Link("Homepage", destination: homepage)
                }
                if !component.copyrights.isEmpty {
                    Text(component.copyrights.joined(separator: "\n"))
                        .font(.footnote.monospaced())
                }
                licenseBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .textSelection(.enabled)
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { loadLicenseTextIfNeeded() }
    }

    @ViewBuilder
    private var licenseBlock: some View {
        switch licenseText {
        case .loading:
            ProgressView()
        case .loaded(let text):
            Text(text)
                .font(.caption.monospaced())
        case .failed:
            Text("The license text is missing from this build.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func loadLicenseTextIfNeeded() {
        guard case .loading = licenseText else { return }
        do {
            licenseText = .loaded(try inventory.licenseText(for: component))
        } catch {
            licenseText = .failed(error)
        }
    }
}
