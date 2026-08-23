//
//  MCPToolRegistryGuardTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCPToolRegistry contract")
struct MCPToolRegistryGuardTests {
    private static let nameCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")

    private func schemas(of tool: any MCPToolImplementation) -> [(label: String, schema: JsonValue)] {
        let toolType = type(of: tool)
        var found: [(String, JsonValue)] = [("inputSchema", toolType.inputSchema)]
        if let output = toolType.outputSchema {
            found.append(("outputSchema", output))
        }
        return found
    }

    private func referenceKeys(in value: JsonValue) -> [String] {
        switch value {
        case .object(let fields):
            var found: [String] = []
            for (key, nested) in fields {
                if key == "$ref" || key == "$dynamicRef" {
                    found.append(key)
                }
                found.append(contentsOf: referenceKeys(in: nested))
            }
            return found
        case .array(let items):
            return items.flatMap { referenceKeys(in: $0) }
        default:
            return []
        }
    }

    @Test("Every registered tool declares an output schema")
    func everyToolDeclaresAnOutputSchema() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            #expect(toolType.outputSchema != nil, "\(toolType.name) has no outputSchema")
        }
    }

    @Test("Every input schema roots at an object")
    func everyInputSchemaRootsAtAnObject() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            #expect(
                toolType.inputSchema["type"]?.stringValue == "object",
                "\(toolType.name) inputSchema is not an object"
            )
        }
    }

    @Test("Every output schema roots at an object")
    func everyOutputSchemaRootsAtAnObject() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            guard let output = toolType.outputSchema else { continue }
            #expect(
                output["type"]?.stringValue == "object",
                "\(toolType.name) outputSchema is not an object"
            )
        }
    }

    @Test("No schema uses a JSON Schema reference the client would have to dereference")
    func noSchemaUsesReferences() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            for entry in schemas(of: tool) {
                let references = referenceKeys(in: entry.schema)
                #expect(
                    references.isEmpty,
                    "\(toolType.name) \(entry.label) contains \(references.joined(separator: ", "))"
                )
            }
        }
    }

    @Test("Every tool name fits the 1 to 128 character naming rule")
    func everyToolNameFitsTheNamingRule() {
        for tool in MCPToolRegistry.allTools {
            let name = type(of: tool).name
            #expect(!name.isEmpty, "a tool has an empty name")
            #expect(name.count <= 128, "\(name) is longer than 128 characters")
            let illegal = name.unicodeScalars.filter { !Self.nameCharacters.contains($0) }
            #expect(
                illegal.isEmpty,
                "\(name) uses characters outside A-Z a-z 0-9 _ - ."
            )
        }
    }

    @Test("Tool names are unique within the server")
    func toolNamesAreUnique() {
        let names = MCPToolRegistry.allTools.map { type(of: $0).name }
        #expect(Set(names).count == names.count, "duplicate tool name in the registry")
    }

    @Test("Every registered tool resolves by name")
    func everyToolResolvesByName() {
        for tool in MCPToolRegistry.allTools {
            let name = type(of: tool).name
            #expect(MCPToolRegistry.tool(named: name) != nil, "\(name) does not resolve")
        }
        #expect(MCPToolRegistry.tool(named: "not_a_tool") == nil)
    }

    @Test("Every required property is declared in the schema's properties")
    func requiredPropertiesAreDeclared() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            for entry in schemas(of: tool) {
                let required = entry.schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let declared = entry.schema["properties"]?.objectValue ?? [:]
                for key in required {
                    #expect(
                        declared[key] != nil,
                        "\(toolType.name) \(entry.label) requires '\(key)' but never declares it"
                    )
                }
            }
        }
    }

    @Test("A read-only scope set never yields a tool that needs write")
    func readOnlyScopesNeverYieldWriteTools() {
        let readOnly = MCPToolRegistry.tools(for: MCPScope.readOnlySet)
        #expect(!readOnly.isEmpty)
        for tool in readOnly {
            #expect(
                !type(of: tool).requiredScopes.contains(.toolsWrite),
                "\(type(of: tool).name) leaked into the read-only tool list"
            )
        }
        let readWrite = MCPToolRegistry.tools(for: MCPScope.readWriteSet)
        #expect(readWrite.count > readOnly.count)
    }

    @Test("A tool that needs write never claims to be read-only")
    func writeToolsNeverClaimReadOnly() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            guard toolType.requiredScopes.contains(.toolsWrite) else { continue }
            #expect(
                toolType.annotations.readOnlyHint != true,
                "\(toolType.name) needs tools:write but hints readOnly"
            )
        }
    }

    @Test("A tool that hints destructive needs the write scope")
    func destructiveToolsNeedWriteScope() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            guard toolType.annotations.destructiveHint == true else { continue }
            #expect(
                toolType.requiredScopes.contains(.toolsWrite),
                "\(toolType.name) hints destructive without needing tools:write"
            )
        }
    }

    @Test("Every descriptor carries the fields tools/list promises")
    func descriptorsCarryTheAdvertisedFields() {
        for tool in MCPToolRegistry.allTools {
            let toolType = type(of: tool)
            let descriptor = MCPToolRegistry.descriptor(for: tool)
            #expect(descriptor["name"]?.stringValue == toolType.name)
            #expect(descriptor["description"]?.stringValue?.isEmpty == false, "\(toolType.name) has no description")
            #expect(descriptor["inputSchema"] != nil, "\(toolType.name) descriptor drops inputSchema")
            #expect(descriptor["outputSchema"] != nil, "\(toolType.name) descriptor drops outputSchema")
            #expect(descriptor["title"]?.stringValue?.isEmpty == false, "\(toolType.name) has no title")
            #expect(descriptor["annotations"] != nil, "\(toolType.name) descriptor drops annotations")
        }
    }

    @Test("Descriptors are sorted by name so the list is stable between calls")
    func descriptorsAreStablySorted() {
        let names = MCPToolRegistry.descriptors(for: MCPScope.fullAccessSet)
            .compactMap { $0["name"]?.stringValue }
        #expect(names == names.sorted())
        #expect(names.count == MCPToolRegistry.allTools.count)
    }
}
