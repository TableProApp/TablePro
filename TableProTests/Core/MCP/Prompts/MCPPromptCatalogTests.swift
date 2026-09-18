import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCPPromptCatalog")
struct MCPPromptCatalogTests {
    @Test("The catalog advertises at least one prompt")
    func catalogIsNotEmpty() {
        #expect(!MCPPromptCatalog.all.isEmpty)
    }

    @Test("Prompt names are unique")
    func promptNamesAreUnique() {
        let names = MCPPromptCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Every prompt names itself, titles itself, and describes itself")
    func everyPromptCarriesItsOwnMetadata() {
        for prompt in MCPPromptCatalog.all {
            #expect(!prompt.name.isEmpty)
            #expect(!prompt.title.isEmpty)
            #expect(!prompt.description.isEmpty)
        }
    }

    @Test("Every catalogued name resolves and an unknown one does not")
    func lookupByName() {
        for prompt in MCPPromptCatalog.all {
            #expect(MCPPromptCatalog.prompt(named: prompt.name)?.name == prompt.name)
        }
        #expect(MCPPromptCatalog.prompt(named: "no_such_prompt") == nil)
    }

    @Test("Every prompt requires a connection so nothing renders against an unnamed database")
    func everyPromptRequiresAConnection() {
        for prompt in MCPPromptCatalog.all {
            let connection = prompt.argument(named: MCPPromptArgument.connectionArgumentName)
            #expect(connection != nil, "\(prompt.name) has no connection argument")
            #expect(connection?.isRequired == true, "\(prompt.name) does not require its connection argument")
            #expect(connection?.completion == .connection)
        }
    }

    @Test("Argument names are unique inside a prompt")
    func argumentNamesAreUniquePerPrompt() {
        for prompt in MCPPromptCatalog.all {
            let names = prompt.arguments.map(\.name)
            #expect(Set(names).count == names.count, "\(prompt.name) declares a duplicate argument")
        }
    }

    @Test("Every argument names itself, titles itself, and describes itself")
    func everyArgumentCarriesItsOwnMetadata() {
        for prompt in MCPPromptCatalog.all {
            for argument in prompt.arguments {
                #expect(!argument.name.isEmpty)
                #expect(!argument.title.isEmpty, "\(prompt.name).\(argument.name) has no title")
                #expect(!argument.description.isEmpty, "\(prompt.name).\(argument.name) has no description")
            }
        }
    }

    @Test("Argument lookup crosses prompt and argument name")
    func argumentLookup() {
        let audience = MCPPromptCatalog.argument(promptName: "explain_schema", argumentName: "audience")
        #expect(audience?.completion == .values(MCPPromptCatalog.audiences))
        #expect(MCPPromptCatalog.argument(promptName: "explain_schema", argumentName: "nope") == nil)
        #expect(MCPPromptCatalog.argument(promptName: "nope", argumentName: "audience") == nil)
    }

    @Test("Enumerated completions offer a non-empty, duplicate-free value set")
    func enumeratedCompletionsAreUsable() {
        for prompt in MCPPromptCatalog.all {
            for argument in prompt.arguments {
                guard case .values(let values) = argument.completion else { continue }
                #expect(!values.isEmpty, "\(prompt.name).\(argument.name) offers no values")
                #expect(Set(values).count == values.count, "\(prompt.name).\(argument.name) repeats a value")
            }
        }
    }

    @Test("A prompt serialises name, title, description, and its declared arguments")
    func promptJsonShape() throws {
        let prompt = try #require(MCPPromptCatalog.prompt(named: "explain_table"))
        let json = prompt.asJsonValue

        #expect(json["name"]?.stringValue == "explain_table")
        #expect(json["title"]?.stringValue == prompt.title)
        #expect(json["description"]?.stringValue == prompt.description)

        let arguments = try #require(json["arguments"]?.arrayValue)
        #expect(arguments.count == prompt.arguments.count)

        let table = try #require(arguments.first { $0["name"]?.stringValue == "table" })
        #expect(table["required"]?.boolValue == true)
        #expect(table["title"]?.stringValue?.isEmpty == false)
        #expect(table["description"]?.stringValue?.isEmpty == false)
    }

    @Test("A prompt with no arguments omits the arguments key entirely")
    func promptWithoutArgumentsOmitsTheKey() {
        let prompt = MCPPromptDefinition(
            name: "bare",
            title: "Bare",
            description: "No arguments",
            arguments: [],
            render: { _ in MCPPromptRendering(description: "", messages: []) }
        )
        #expect(prompt.asJsonValue["arguments"] == nil)
    }

    @Test("A rendered message serialises as a text content block")
    func messageJsonShape() {
        let message = MCPPromptMessage.user("hello")
        #expect(message.asJsonValue["role"]?.stringValue == "user")
        #expect(message.asJsonValue["content"]?["type"]?.stringValue == "text")
        #expect(message.asJsonValue["content"]?["text"]?.stringValue == "hello")
        #expect(MCPPromptMessage.assistant("hi").asJsonValue["role"]?.stringValue == "assistant")
    }

    @Test("A rendering becomes a description plus a message array")
    func renderingPayloadShape() throws {
        let rendering = MCPPromptRendering(
            description: "Schema tour",
            messages: [.user("first"), .assistant("second")]
        )
        let payload = rendering.asPayload
        #expect(payload["description"]?.stringValue == "Schema tour")
        let messages = try #require(payload["messages"]?.arrayValue)
        #expect(messages.count == 2)
        #expect(messages[0]["role"]?.stringValue == "user")
        #expect(messages[1]["role"]?.stringValue == "assistant")
    }

    @Test("A blank argument reads as absent at every accessor")
    func blankArgumentsReadAsAbsent() {
        let context = PromptCatalogTestSupport.renderContext(arguments: ["table": "   ", "schema": ""])
        #expect(context.value("table") == nil)
        #expect(context.value("schema") == nil)
        #expect(context.value("missing") == nil)
        #expect(context.list("table").isEmpty)
    }

    @Test("A required argument that is missing fails with invalid params")
    func requiredArgumentIsEnforced() {
        let context = PromptCatalogTestSupport.renderContext(arguments: ["table": " orders "])
        #expect(throws: MCPProtocolError.self) {
            _ = try context.requiredValue("question")
        }
        #expect((try? context.requiredValue("table")) == "orders")
    }

    @Test("A choice matches case-insensitively, defaults when absent, and rejects anything else")
    func choiceArgument() throws {
        let allowed = ["today", "this_week", "all"]
        let absent = PromptCatalogTestSupport.renderContext(arguments: [:])
        #expect(try absent.choice("period", allowed: allowed, default: "all") == "all")

        let mixedCase = PromptCatalogTestSupport.renderContext(arguments: ["period": "This_Week"])
        #expect(try mixedCase.choice("period", allowed: allowed, default: "all") == "this_week")

        let invalid = PromptCatalogTestSupport.renderContext(arguments: ["period": "yesterday"])
        let error = PromptCatalogTestSupport.protocolError {
            _ = try invalid.choice("period", allowed: allowed, default: "all")
        }
        #expect(error?.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("An integer argument clamps to its range and rejects non-numbers")
    func integerArgument() throws {
        let range = 1 ... 500
        #expect(try PromptCatalogTestSupport.renderContext(arguments: [:])
            .integer("limit", default: 50, clamp: range) == 50)
        #expect(try PromptCatalogTestSupport.renderContext(arguments: ["limit": "5000"])
            .integer("limit", default: 50, clamp: range) == 500)
        #expect(try PromptCatalogTestSupport.renderContext(arguments: ["limit": "0"])
            .integer("limit", default: 50, clamp: range) == 1)

        let error = PromptCatalogTestSupport.protocolError {
            _ = try PromptCatalogTestSupport.renderContext(arguments: ["limit": "lots"])
                .integer("limit", default: 50, clamp: range)
        }
        #expect(error?.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A list argument splits on commas and drops the empties")
    func listArgument() {
        let context = PromptCatalogTestSupport.renderContext(arguments: ["tables": " orders , ,line_items,, users "])
        #expect(context.list("tables") == ["orders", "line_items", "users"])
        #expect(context.list("missing").isEmpty)
    }
}

enum PromptCatalogTestSupport {
    static func renderContext(
        arguments: [String: String],
        principal: MCPPrincipal = MCPProtocolTestSupport.makePrincipal(scopes: MCPScope.readOnlySet)
    ) -> MCPPromptRenderContext {
        MCPPromptRenderContext(
            principal: principal,
            arguments: arguments,
            schema: MCPPromptSchemaReader(
                services: MCPProtocolHandlerTestSupport.makeToolServices(),
                source: FixedPromptSchemaSource(connections: [])
            )
        )
    }

    static func protocolError(_ body: () throws -> Void) -> MCPProtocolError? {
        do {
            try body()
            return nil
        } catch let error as MCPProtocolError {
            return error
        } catch {
            return nil
        }
    }
}
