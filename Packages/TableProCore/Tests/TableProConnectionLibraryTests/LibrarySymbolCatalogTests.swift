import Foundation
@testable import TableProConnectionLibrary
import Testing

@Suite("Library symbol catalog")
struct LibrarySymbolCatalogTests {
    private static func names(_ sections: [LibrarySymbolSection]) -> [String] {
        sections.flatMap(\.symbols).map(\.name)
    }

    @Test("Every name is unique and is already in its normalized form")
    func namesAreUniqueAndNormalized() {
        let names = LibrarySymbolCatalog.symbols.map(\.name)

        #expect(Set(names).count == names.count)
        for name in names {
            #expect(LibrarySymbolCatalog.normalizedName(name) == name, "\(name) is not a valid stored name")
        }
    }

    @Test("Every title is unique, so VoiceOver tells two cells apart")
    func titlesAreUnique() {
        let titles = LibrarySymbolCatalog.symbols.map(\.title)

        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test("Every category has symbols, and sections follow the category order")
    func everyCategoryIsFilled() {
        let sections = LibrarySymbolCatalog.sections

        #expect(sections.map(\.category) == LibrarySymbolCategory.allCases)
        #expect(sections.allSatisfy { !$0.symbols.isEmpty })
        #expect(sections.allSatisfy { section in section.symbols.allSatisfy { $0.category == section.category } })
    }

    @Test("A symbol is found by its name, and an unknown name finds nothing")
    func lookupByName() {
        #expect(LibrarySymbolCatalog.symbol(named: "server.rack")?.title == "Server")
        #expect(LibrarySymbolCatalog.symbol(named: "made.up.symbol") == nil)
    }

    @Test("An empty or blank query returns the whole catalog in catalog order")
    func emptyQueryReturnsEverything() {
        let everything = LibrarySymbolCatalog.symbols.map(\.name)

        #expect(Self.names(LibrarySymbolCatalog.sections(matching: "")) == everything)
        #expect(Self.names(LibrarySymbolCatalog.sections(matching: "   ")) == everything)
        #expect(Self.names(LibrarySymbolCatalog.sections) == everything)
    }

    @Test("Search matches a title", arguments: ["Stop Sign", "stop sign", "STOP"])
    func searchMatchesTitle(_ query: String) {
        #expect(Self.names(LibrarySymbolCatalog.sections(matching: query)).contains("xmark.octagon"))
    }

    @Test("Search matches a keyword the title does not contain")
    func searchMatchesKeyword() {
        #expect(Self.names(LibrarySymbolCatalog.sections(matching: "docker")) == ["shippingbox"])
    }

    @Test("Search matches a token of the symbol name")
    func searchMatchesNameToken() {
        #expect(Self.names(LibrarySymbolCatalog.sections(matching: "ladybug")) == ["ladybug"])
    }

    @Test("Search keeps catalog order and its category headers")
    func searchKeepsOrderAndHeaders() {
        let sections = LibrarySymbolCatalog.sections(matching: "prod")
        let found = Self.names(sections)
        let catalogOrder = LibrarySymbolCatalog.symbols.map(\.name).filter { found.contains($0) }

        #expect(found.contains("flame"))
        #expect(found == catalogOrder)
        #expect(sections.allSatisfy { !$0.symbols.isEmpty })
    }

    @Test("A query that matches nothing returns no sections")
    func searchWithoutMatches() {
        #expect(LibrarySymbolCatalog.sections(matching: "zzzqqq").isEmpty)
    }

    @Test("Best match prefers an exact title over an earlier title prefix")
    func bestMatchPrefersExactTitle() {
        let symbols = [
            LibrarySymbol("a", .development, "Serverless", []),
            LibrarySymbol("b", .development, "Server", [])
        ]

        #expect(LibrarySymbolCatalog.bestMatch(for: "server", in: symbols)?.name == "b")
    }

    @Test("Best match takes an exact name too")
    func bestMatchTakesExactName() {
        let symbols = [
            LibrarySymbol("cylinder.split", .development, "Cylinders", []),
            LibrarySymbol("cylinder", .development, "Database", [])
        ]

        #expect(LibrarySymbolCatalog.bestMatch(for: "cylinder", in: symbols)?.name == "cylinder")
    }

    @Test("Best match prefers a title prefix over an earlier keyword prefix")
    func bestMatchPrefersTitlePrefix() {
        let symbols = [
            LibrarySymbol("a", .development, "Flame", ["production"]),
            LibrarySymbol("b", .development, "Products", [])
        ]

        #expect(LibrarySymbolCatalog.bestMatch(for: "prod", in: symbols)?.name == "b")
    }

    @Test("Best match falls back to a keyword prefix")
    func bestMatchUsesKeywordPrefix() {
        let symbols = [
            LibrarySymbol("a", .development, "Leaf", ["sandbox"]),
            LibrarySymbol("b", .development, "Flame", ["live", "production"])
        ]

        #expect(LibrarySymbolCatalog.bestMatch(for: "Prod", in: symbols)?.name == "b")
    }

    @Test("A substring-only match, or an empty query, picks nothing")
    func bestMatchIgnoresSubstrings() {
        let symbols = [LibrarySymbol("a", .development, "Reproduce", ["unproductive"])]

        #expect(LibrarySymbolCatalog.bestMatch(for: "prod", in: symbols) == nil)
        #expect(LibrarySymbolCatalog.bestMatch(for: "  ", in: symbols) == nil)
    }

    @Test(
        "A name that is not shaped like an SF Symbol is rejected",
        arguments: ["", "  ", "A", "Server.rack", "a..b", ".a", "a.", "a/b", "../x", "a b", "a-b", "café", "日本"]
    )
    func normalizedNameRejectsJunk(_ raw: String) {
        #expect(LibrarySymbolCatalog.normalizedName(raw) == nil)
    }

    @Test("A name longer than the limit is rejected, and one at the limit is kept")
    func normalizedNameCapsLength() {
        let limit = LibrarySymbolCatalog.maximumNameLength
        let atLimit = String(repeating: "a", count: limit)

        #expect(LibrarySymbolCatalog.normalizedName(atLimit) == atLimit)
        #expect(LibrarySymbolCatalog.normalizedName(atLimit + "a") == nil)
    }

    @Test("Surrounding whitespace is trimmed, and nil stays nil")
    func normalizedNameTrims() {
        #expect(LibrarySymbolCatalog.normalizedName(" server.rack\n") == "server.rack")
        #expect(LibrarySymbolCatalog.normalizedName(nil) == nil)
    }

    @Test("A well-formed name outside the catalog is kept, since a newer release may offer it")
    func normalizedNameKeepsUnknownNames() {
        #expect(LibrarySymbolCatalog.normalizedName("made.up.symbol") == "made.up.symbol")
        #expect(LibrarySymbolCatalog.normalizedName("cylinder.split.1x2") == "cylinder.split.1x2")
    }
}
