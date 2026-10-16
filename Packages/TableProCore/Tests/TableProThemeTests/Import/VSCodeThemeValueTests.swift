import Foundation
@testable import TableProTheme
import Testing

struct VSCodeThemeValueTests {
    private static func nestedArrays(_ levels: Int) -> String {
        String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
    }

    private static func nestedPropertyList(_ levels: Int) -> Any {
        var value: Any = "leaf"
        for _ in 0 ..< levels {
            value = [value]
        }
        return value
    }

    @Test("JSON nests at most 32 arrays and objects, and the refusal is not lost as a type mismatch")
    func jsonDepthCap() throws {
        let objects = String(repeating: #"{"a": "#, count: 33) + "1" + String(repeating: "}", count: 33)

        #expect(throws: Never.self) { try VSCodeThemeValue.parse(Data(Self.nestedArrays(32).utf8)) }
        #expect(throws: ThemeLoadError.nestingTooDeep(limit: 32)) { try VSCodeThemeValue.parse(Data(Self.nestedArrays(33).utf8)) }
        #expect(throws: ThemeLoadError.nestingTooDeep(limit: 32)) { try VSCodeThemeValue.parse(Data(objects.utf8)) }
    }

    @Test("JSON nested 100,000 levels is refused, not decoded one stack frame per level", .timeLimit(.minutes(1)))
    func jsonFarPastTheCap() {
        #expect(throws: ThemeLoadError.self) { try VSCodeThemeValue.parse(Data(Self.nestedArrays(100_000).utf8)) }
    }

    @Test("Objects and arrays keep their values and keys after the element-wise decode")
    func jsonShapes() throws {
        let value = try VSCodeThemeValue.parse(Data(#"{"a": [1, "b", true, null], "c": {"d": "e"}}"#.utf8))

        #expect(value == .object([
            "a": .array([.number(1), .string("b"), .bool(true), .null]),
            "c": .object(["d": .string("e")]),
        ]))
    }

    @Test("A property list nests at most 32 arrays and dictionaries")
    func propertyListDepthCap() {
        #expect(VSCodeThemeValue(propertyList: Self.nestedPropertyList(32)) != nil)
        #expect(VSCodeThemeValue(propertyList: Self.nestedPropertyList(33)) == nil)
    }

    @Test("A property list graph that repeats its containers stops at the value budget", .timeLimit(.minutes(1)))
    func propertyListBudget() {
        var shared: Any = "leaf"
        for _ in 0 ..< 30 {
            shared = [shared, shared]
        }
        let fits = Array(repeating: "x", count: VSCodeThemeValue.maximumPropertyListValues - 1)

        #expect(VSCodeThemeValue(propertyList: shared) == nil)
        #expect(VSCodeThemeValue(propertyList: fits) != nil)
        #expect(VSCodeThemeValue(propertyList: fits + ["one more"]) == nil)
    }

    @Test("A binary property list read back keeps its sharing, and the conversion still stops", .timeLimit(.minutes(1)))
    func parsedSharedGraph() throws {
        let propertyList = try PropertyListSerialization.propertyList(
            from: SharedReferencePropertyList.make(levels: 30),
            options: [],
            format: nil
        )

        #expect(VSCodeThemeValue(propertyList: propertyList) == nil)
    }

    @Test("A property list converts strings, numbers, booleans, arrays and dictionaries")
    func propertyListShapes() {
        let value = VSCodeThemeValue(propertyList: ["a": ["b", 2, true] as [Any], "c": Date()] as [String: Any])

        #expect(value == .object(["a": .array([.string("b"), .number(2), .number(1)]), "c": .null]))
    }
}
