//
//  BrandIconTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

struct BrandIconTests {
    private static func catalogIconSlugs() throws -> [String] {
        let url = try #require(Bundle.main.url(forResource: "clients", withExtension: "json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let catalog = try #require(object as? [String: Any])
        let clients = try #require(catalog["clients"] as? [[String: Any]])
        return try clients.map { client in
            try #require(client["icon"] as? String, "\(client["id"] ?? "a client") has no icon")
        }
    }

    private static var providerIcons: [(name: String, icon: BrandIcon)] {
        AIProviderType.allCases.map { ($0.rawValue, $0.icon) } + AIProviderPreset.all.map { ($0.id, $0.icon) }
    }

    private static func visiblePixelCount(of image: NSImage, side: Int) throws -> Int {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }

    @Test("Every client icon in the bundled catalog is an asset in the app")
    func catalogIconsResolve() throws {
        let slugs = try Self.catalogIconSlugs()
        #expect(!slugs.isEmpty)
        for slug in Set(slugs) {
            #expect(NSImage(named: BrandIcon.assetName(for: slug)) != nil, "\(slug)-icon is missing")
        }
    }

    @Test("Every AI provider and preset icon is an asset, and its fallback is an SF Symbol")
    func providerIconsResolve() {
        for (name, icon) in Self.providerIcons {
            if let slug = icon.slug {
                #expect(icon.assetImage != nil, "\(name): \(slug)-icon is missing")
            }
            #expect(
                NSImage(systemSymbolName: icon.fallbackSystemImage, accessibilityDescription: nil) != nil,
                "\(name): \(icon.fallbackSystemImage) is not an SF Symbol"
            )
        }
    }

    @Test("A custom provider has no brand and draws its SF Symbol")
    func customProviderFallsBack() {
        let icon = AIProviderType.custom.icon
        #expect(icon.slug == nil)
        #expect(icon.assetImage == nil)
        #expect(icon.nsImage() != nil)
    }

    @Test("A slug with no asset draws the fallback symbol")
    func missingAssetFallsBack() throws {
        let icon = BrandIcon(slug: "no-such-brand", fallbackSystemImage: "server.rack")
        #expect(icon.assetImage == nil)
        let image = try #require(icon.nsImage())
        #expect(image.isTemplate)
    }

    @Test("The menu copy is the asked square and keeps the asset's template flag")
    func menuCopyKeepsTemplateFlag() throws {
        let template = try #require(BrandIcon(slug: "claude", fallbackSystemImage: "brain").nsImage(pointSize: 16))
        #expect(template.size == NSSize(width: 16, height: 16))
        #expect(template.isTemplate)

        let original = try #require(BrandIcon(slug: "vscode", fallbackSystemImage: "curlybraces").nsImage())
        #expect(original.size == NSSize(width: 16, height: 16))
        #expect(!original.isTemplate)
    }

    // A one-color official mark is a template; a multicolor one keeps its colors, which VS Code's brand terms require.
    @Test("Only the brands whose official logo has several colors skip template rendering")
    func onlyMulticolorLogosAreOriginal() throws {
        let slugs = try Set(Self.catalogIconSlugs() + Self.providerIcons.compactMap { $0.icon.slug })
        let original = slugs.filter { slug in
            NSImage(named: BrandIcon.assetName(for: slug))?.isTemplate == false
        }
        #expect(original == ["kiro", "mlx", "requesty", "vscode"])
    }

    @Test("Every brand asset draws something at menu size")
    @MainActor
    func everyAssetDraws() throws {
        let slugs = try Set(Self.catalogIconSlugs() + Self.providerIcons.compactMap { $0.icon.slug })
        for slug in slugs {
            let image = try #require(BrandIcon(slug: slug, fallbackSystemImage: "questionmark").nsImage(pointSize: 16))
            #expect(try Self.visiblePixelCount(of: image, side: 32) > 0, "\(slug)-icon draws nothing")
        }
    }
}
