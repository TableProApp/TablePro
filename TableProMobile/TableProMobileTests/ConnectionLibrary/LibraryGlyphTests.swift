import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing
import UIKit

@Suite("Library glyph")
struct LibraryGlyphTests {
    @Test("Every symbol the picker offers draws on this iOS")
    func everyCatalogSymbolResolves() {
        let missing = LibrarySymbolCatalog.symbols.map(\.name).filter { UIImage(systemName: $0) == nil }

        #expect(missing.isEmpty, "Missing symbols: \(missing)")
    }

    @Test("A custom icon draws only when it is a symbol this device has")
    func customSymbolNeedsADrawableName() {
        #expect(LibraryGlyph.customSymbol("server.rack") == "server.rack")
        #expect(LibraryGlyph.customSymbol(" flame ") == "flame")
        #expect(LibraryGlyph.customSymbol("made.up.symbol") == nil)
        #expect(LibraryGlyph.customSymbol("Server Rack") == nil)
        #expect(LibraryGlyph.customSymbol(nil) == nil)
    }

    @Test("A group draws the filled variant when there is one, and the outline when there is not")
    func groupSymbolPrefersFill() {
        #expect(LibraryGlyph.groupSymbol(nil) == "folder.fill")
        #expect(LibraryGlyph.groupSymbol("briefcase") == "briefcase.fill")
        #expect(LibraryGlyph.groupSymbol("function") == "function")
        #expect(LibraryGlyph.groupSymbol("made.up.symbol") == "folder.fill")
    }

    @Test("A connection draws its custom icon in place of the engine glyph")
    func connectionGlyphPrefersCustomIcon() {
        #expect(
            LibraryGlyph.connectionGlyph(type: .postgresql, iconName: "flame")
                == ConnectionGlyph(source: .symbol, name: "flame")
        )
        #expect(
            LibraryGlyph.connectionGlyph(type: .postgresql, iconName: nil)
                == ConnectionGlyph(source: .asset, name: "postgresql-icon")
        )
        #expect(
            LibraryGlyph.connectionGlyph(type: .postgresql, iconName: "made.up.symbol")
                == ConnectionGlyph(source: .asset, name: "postgresql-icon")
        )
    }

    @Test("An engine draws its asset, its symbol, or the fallback when this app has no asset for it")
    func engineGlyphFallsBack() {
        #expect(LibraryGlyph.engineGlyph(for: .mysql) == ConnectionGlyph(source: .asset, name: "mysql-icon"))
        #expect(LibraryGlyph.engineGlyph(for: .dameng) == ConnectionGlyph(source: .symbol, name: "cylinder"))
        #expect(LibraryGlyph.engineGlyph(for: .snowflake) == .fallback)
        #expect(
            LibraryGlyph.engineGlyph(for: DatabaseType(rawValue: "FuturePlugin"))
                == ConnectionGlyph(source: .symbol, name: "externaldrive")
        )
    }

    @Test("The icon is named by its catalog title, and by Default when it draws the default")
    func titleNamesTheDrawnIcon() {
        #expect(LibraryGlyph.title(for: "server.rack") == LibrarySymbolCatalog.symbol(named: "server.rack")?.title)
        #expect(LibraryGlyph.title(for: nil) == String(localized: "Default"))
        #expect(LibraryGlyph.title(for: "made.up.symbol") == String(localized: "Default"))
    }
}
