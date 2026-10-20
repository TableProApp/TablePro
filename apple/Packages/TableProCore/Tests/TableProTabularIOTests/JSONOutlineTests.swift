import Foundation
@testable import TableProTabularIO
import Testing

struct JSONOutlineTests {
    private func outline(_ text: String) -> (root: JSONOutlineNode, omitted: Int)? {
        guard case .tree(let root, let omitted) = JSONOutline.build(text) else { return nil }
        return (root, omitted)
    }

    private func child(_ node: JSONOutlineNode, _ position: Int) throws -> JSONOutlineNode {
        let children = try #require(node.children)
        try #require(position < children.count)
        return children[position]
    }

    private func allNodes(_ root: JSONOutlineNode) -> [JSONOutlineNode] {
        var nodes: [JSONOutlineNode] = []
        var pending = [root]
        while let node = pending.popLast() {
            nodes.append(node)
            pending.append(contentsOf: node.children ?? [])
        }
        return nodes
    }

    private func isTooLarge(_ result: JSONOutline.Result) -> Bool {
        if case .tooLarge = result { return true }
        return false
    }

    private func isInvalid(_ result: JSONOutline.Result) -> Bool {
        if case .invalid = result { return true }
        return false
    }

    @Test func namesEachValueByItsKeyPath() throws {
        let tree = try #require(outline(#"{"user":{"name":"a","emails":["x@y.z"]},"tags":[1,2,3]}"#))
        let root = tree.root
        #expect(root.key == .root)
        #expect(root.keyPath == "$")
        #expect(root.value == .object(count: 2))
        #expect(tree.omitted == 0)

        let user = try child(root, 0)
        #expect(user.key == .member("user"))
        #expect(user.keyPath == "$.user")
        let emails = try child(user, 1)
        #expect(emails.keyPath == "$.user.emails")
        #expect(emails.value == .array(count: 1))
        let email = try child(emails, 0)
        #expect(email.key == .index(0))
        #expect(email.keyPath == "$.user.emails[0]")
        #expect(email.value == .string("x@y.z"))
        #expect(email.children == nil)

        let tags = try child(root, 1)
        let three = try child(tags, 2)
        #expect(three.keyPath == "$.tags[2]")
        #expect(three.value == .number("3"))
        #expect(Set(allNodes(root).map { $0.id }) == Set(0..<9))
    }

    @Test func quotesKeysThatAreNotIdentifiers() throws {
        let tree = try #require(outline(#"{"content-type":1,"a.b":2,"say \"hi\"":3,"_ok9":4,"9lives":5,"":6,"é":7,"back\\slash":8}"#))
        let members = try #require(tree.root.children)
        #expect(members.map { $0.keyPath } == [
            #"$."content-type""#, #"$."a.b""#, #"$."say \"hi\"""#, "$._ok9", #"$."9lives""#, "$.\"\"", #"$."é""#, #"$."back\\slash""#
        ])
        #expect(members[2].key == .member(#"say "hi""#))
        #expect(members[7].key == .member(#"back\slash"#))
    }

    @Test func duplicateKeysGetTheirOwnNodes() throws {
        let tree = try #require(outline(#"{"a":1,"a":{"a":2}}"#))
        let members = try #require(tree.root.children)
        #expect(members.map { $0.keyPath } == ["$.a", "$.a"])
        #expect(members[0].id != members[1].id)
        #expect(members[0].value == .number("1"))
        #expect(members[1].value == .object(count: 1))
        #expect(Set(allNodes(tree.root).map { $0.id }).count == 4)
    }

    @Test func idsFollowPositionSoReindentedTextKeepsThem() throws {
        let compact = #"{"user":{"name":"a","emails":["x@y.z"]},"tags":[1,2,3]}"#
        let pretty = try #require(JSONPrettyPrinter.format(compact))
        let first = try #require(outline(compact))
        let second = try #require(outline(pretty))
        #expect(allNodes(first.root).map { $0.id } == allNodes(second.root).map { $0.id })
        #expect(allNodes(first.root).map { $0.keyPath } == allNodes(second.root).map { $0.keyPath })
    }

    @Test func stopsBuildingAtFiveThousandNodesAndCountsTheRest() throws {
        let text = "[" + (0..<6_000).map { String($0) }.joined(separator: ",") + "]"
        let tree = try #require(outline(text))
        #expect(tree.root.value == .array(count: 6_000))
        #expect(tree.root.children?.count == 4_999)
        #expect(tree.root.children?.last?.value == .number("4998"))
        #expect(tree.omitted == 1_001)
    }

    @Test func countsTheDescendantsOfEveryValueLeftOut() throws {
        let text = "[" + Array(repeating: "[0,0]", count: 3_000).joined(separator: ",") + "]"
        let tree = try #require(outline(text))
        let pairs = try #require(tree.root.children)
        #expect(pairs.count == 1_667)
        #expect(pairs.last?.value == .array(count: 2))
        #expect(pairs.last?.children == nil)
        #expect(allNodes(tree.root).count == 5_000)
        #expect(tree.omitted == 4_001)
    }

    @Test func walksSixHundredLevels() throws {
        let text = String(repeating: "[", count: 600) + "1" + String(repeating: "]", count: 600)
        let tree = try #require(outline(text))
        var node = tree.root
        for _ in 0..<600 {
            node = try child(node, 0)
        }
        #expect(node.value == .number("1"))
        #expect(node.keyPath == "$" + String(repeating: "[0]", count: 600))
        #expect(allNodes(tree.root).count == 601)
    }

    @Test func capsADeepChainAtTheNodeLimit() throws {
        let text = String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000)
        let tree = try #require(outline(text))
        #expect(allNodes(tree.root).count == 5_000)
        #expect(tree.omitted == 45_000)
    }

    @Test func cutsLongStringsAtThreeHundredUnitsAndCopiesThemWhole() throws {
        let long = String(repeating: "a", count: 400)
        let cut = try #require(outline("\"" + long + "\""))
        #expect(cut.root.value == .string(String(repeating: "a", count: 300) + "…"))
        #expect(cut.root.copyText == long)

        let exact = String(repeating: "b", count: 300)
        let whole = try #require(outline("\"" + exact + "\""))
        #expect(whole.root.value == .string(exact))

        let emoji = try #require(outline("\"" + String(repeating: "c", count: 299) + "\u{1F44D}\u{1F3FD}\""))
        #expect(emoji.root.value == .string(String(repeating: "c", count: 299) + "…"))
    }

    @Test func decodesEscapesInKeysAndStrings() throws {
        let tree = try #require(outline(#"{"k\u00e9y":"line\nbreak \ud83d\ude00"}"#))
        let member = try child(tree.root, 0)
        #expect(member.key == .member("k\u{E9}y"))
        #expect(member.keyPath == "$.\"k\u{E9}y\"")
        #expect(member.value == .string("line\nbreak \u{1F600}"))
        #expect(member.copyText == "line\nbreak \u{1F600}")
    }

    @Test func copiesContainersCompactWithTheirLexemes() throws {
        let tree = try #require(outline(#"{ "a" : [ 1.50 , 1E+2 , true , null ] , "s" : "x y" }"#))
        #expect(tree.root.copyText == #"{"a":[1.50,1E+2,true,null],"s":"x y"}"#)
        let array = try child(tree.root, 0)
        #expect(array.copyText == "[1.50,1E+2,true,null]")
        #expect(try child(array, 0).copyText == "1.50")
        #expect(try child(array, 1).value == .number("1E+2"))
        #expect(try child(array, 2).value == .bool(true))
        #expect(try child(array, 2).copyText == "true")
        #expect(try child(array, 3).value == .null)
        #expect(try child(array, 3).copyText == "null")
        #expect(try child(tree.root, 1).copyText == "x y")
    }

    @Test func emptyContainersHaveNoChildren() throws {
        let tree = try #require(outline(#"{"a":{},"b":[ ]}"#))
        let members = try #require(tree.root.children)
        #expect(members.map { $0.value } == [.object(count: 0), .array(count: 0)])
        #expect(members.allSatisfy { $0.children == nil })
    }

    @Test func aScalarDocumentIsOneNode() throws {
        let tree = try #require(outline("  true \n"))
        #expect(tree.root.id == 0)
        #expect(tree.root.key == .root)
        #expect(tree.root.value == .bool(true))
        #expect(tree.root.keyPath == "$")
        #expect(tree.root.children == nil)
    }

    @Test func refusesTextAboveOneHundredThousandCharacters() {
        #expect(outline("\"" + String(repeating: "a", count: 99_998) + "\"") != nil)
        #expect(isTooLarge(JSONOutline.build("\"" + String(repeating: "a", count: 99_999) + "\"")))
        #expect(isTooLarge(JSONOutline.build(String(repeating: "x", count: 100_001))))
    }

    @Test(arguments: ["", "  ", #"{"a":}"#, "01", "[1,]", #"{"a":1}x"#, "[\"a\tb\"]", #"{"a" 1}"#, "[1}"])
    func refusesInvalidText(_ text: String) {
        #expect(isInvalid(JSONOutline.build(text)))
    }
}
