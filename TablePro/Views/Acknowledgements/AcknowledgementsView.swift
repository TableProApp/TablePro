//
//  AcknowledgementsView.swift
//  TablePro
//

import SwiftUI

struct AcknowledgementsView: View {
    let inventory: ThirdPartyLicenseInventory?

    @State private var selection: ThirdPartyComponent.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    @ViewBuilder
    private var sidebar: some View {
        if let inventory {
            List(selection: $selection) {
                Section(String(localized: "Open Source Libraries")) {
                    ForEach(inventory.attributed) { component in
                        row(for: component)
                    }
                }
                if !inventory.unresolved.isEmpty {
                    Section(String(localized: "License Not Yet Confirmed")) {
                        ForEach(inventory.unresolved) { component in
                            row(for: component)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView(
                String(localized: "No License Information"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(String(localized: "The list of open source libraries is missing from this build."))
            )
        }
    }

    private func row(for component: ThirdPartyComponent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(component.name)
            Text(component.isUnverified ? component.version : "\(component.version) · \(component.spdx)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(component.id)
    }

    @ViewBuilder
    private var detail: some View {
        if let inventory, let component = selectedComponent(in: inventory) {
            ComponentLicenseDetail(component: component, text: inventory.licenseText(for: component))
        } else {
            ContentUnavailableView(
                String(localized: "Select a Library"),
                systemImage: "sidebar.left",
                description: Text(String(localized: "TablePro includes these open source libraries. Pick one to read its license."))
            )
        }
    }

    private func selectedComponent(in inventory: ThirdPartyLicenseInventory) -> ThirdPartyComponent? {
        guard let selection else { return nil }
        return inventory.components.first { $0.id == selection }
    }
}

private struct ComponentLicenseDetail: View {
    let component: ThirdPartyComponent
    let text: String?

    private var unverifiedExplanation: String {
        String(
            localized: """
            This library's own project publishes no license file, so TablePro cannot state one \
            for it. It is listed here so the gap stays visible instead of looking settled.
            """
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let notes = component.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !component.copyrights.isEmpty {
                    copyrightBlock
                }
                licenseBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(component.name)
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(component.version)
                if !component.isUnverified {
                    Text(component.spdx)
                }
                if component.patched {
                    Text(String(localized: "Modified"))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            links
        }
    }

    private var links: some View {
        HStack(spacing: 14) {
            if let url = URL(string: component.homepageURL) {
                Link(String(localized: "Homepage"), destination: url)
            }
            if let url = URL(string: component.licenseTextURL) {
                Link(String(localized: "License"), destination: url)
            }
        }
        .font(.callout)
    }

    private var copyrightBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(component.copyrights, id: \.self) { line in
                Text(line)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var licenseBlock: some View {
        if let text {
            Text(text)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
        } else if component.isUnverified {
            Text(unverifiedExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(String(localized: "The license text is missing from this build."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
