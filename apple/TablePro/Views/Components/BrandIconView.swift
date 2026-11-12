//
//  BrandIconView.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct BrandIcon: Equatable, Sendable {
    internal let slug: String?
    internal let fallbackSystemImage: String

    internal init(slug: String?, fallbackSystemImage: String) {
        self.slug = slug
        self.fallbackSystemImage = fallbackSystemImage
    }

    internal static func assetName(for slug: String) -> String {
        "\(slug)-icon"
    }

    internal var assetName: String? {
        slug.map(Self.assetName(for:))
    }

    internal var assetImage: NSImage? {
        assetName.flatMap { NSImage(named: $0) }
    }

    // An NSMenu draws an asset at its intrinsic size (Kiro's is 1200 pt), so menus get a copy drawn into a fixed square.
    internal func nsImage(pointSize: CGFloat = 16, accessibilityDescription: String? = nil) -> NSImage? {
        guard let asset = assetImage else {
            return NSImage(systemSymbolName: fallbackSystemImage, accessibilityDescription: accessibilityDescription)
        }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            asset.draw(in: Self.aspectFit(asset.size, in: rect))
            return true
        }
        image.isTemplate = asset.isTemplate
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    internal func menuImage(pointSize: CGFloat = 16) -> Image {
        guard assetImage != nil, let image = nsImage(pointSize: pointSize) else {
            return Image(systemName: fallbackSystemImage)
        }
        return Image(nsImage: image)
    }

    private static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

internal struct BrandIconView: View {
    private let assetName: String?
    private let isTemplate: Bool
    private let fallbackSystemImage: String

    internal init(slug: String, fallbackSystemImage: String) {
        self.init(icon: BrandIcon(slug: slug, fallbackSystemImage: fallbackSystemImage))
    }

    internal init(icon: BrandIcon) {
        if let asset = icon.assetImage {
            assetName = icon.assetName
            isTemplate = asset.isTemplate
        } else {
            assetName = nil
            isTemplate = false
        }
        fallbackSystemImage = icon.fallbackSystemImage
    }

    internal var body: some View {
        Group {
            if let assetName {
                Image(decorative: assetName)
                    .renderingMode(isTemplate ? .template : .original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemImage)
            }
        }
        .accessibilityHidden(true)
    }
}
