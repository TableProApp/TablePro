//
//  WritePolicyMatrix.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import Testing

enum MCPTokenTier: String, CaseIterable, Sendable {
    case readOnly
    case readWrite
    case fullAccess

    var scopes: Set<MCPScope> {
        switch self {
        case .readOnly: return MCPScope.readOnlySet
        case .readWrite: return MCPScope.readWriteSet
        case .fullAccess: return MCPScope.fullAccessSet
        }
    }
}

struct MCPWriteCell: Sendable, CustomStringConvertible {
    let token: MCPTokenTier
    let externalAccess: ExternalAccessLevel
    let aiPolicy: AIConnectionPolicy
    let safeMode: SafeModeLevel

    var description: String {
        "token \(token.rawValue), external \(externalAccess.rawValue), AI \(aiPolicy.rawValue), Safe Mode \(safeMode.rawValue)"
    }

    static let all: [MCPWriteCell] = MCPTokenTier.allCases.flatMap { token in
        ExternalAccessLevel.allCases.flatMap { externalAccess in
            AIConnectionPolicy.allCases.flatMap { aiPolicy in
                SafeModeLevel.allCases.map { safeMode in
                    MCPWriteCell(token: token, externalAccess: externalAccess, aiPolicy: aiPolicy, safeMode: safeMode)
                }
            }
        }
    }
}

// Every tools:write tool, and every read tool that runs a statement the client writes.
enum MCPWritePath: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case executeQuery
    case explainQuery
    case exportData
    case insertRows
    case createDatabase
    case dropDatabaseObject
    case runMaintenance
    case transactionControl
    case confirmDestructiveOperation
    case stopServerSession
    case connect
    case disconnect
    case switchDatabase
    case switchSchema
    case openConnectionWindow
    case openTableTab
    case focusQueryTab

    // Their `query` is text to search for, not a statement.
    static let queryArgumentsThatAreNotStatements: Set<String> = [SearchQueryHistoryTool.name]

    static let writeStatement = "UPDATE matrix_rows SET note = 'x' WHERE id = 1"

    var testDescription: String { toolName }

    var toolName: String {
        switch self {
        case .executeQuery: return ExecuteQueryTool.name
        case .explainQuery: return ExplainQueryTool.name
        case .exportData: return ExportDataTool.name
        case .insertRows: return InsertRowsTool.name
        case .createDatabase: return CreateDatabaseTool.name
        case .dropDatabaseObject: return DropDatabaseObjectTool.name
        case .runMaintenance: return RunMaintenanceTool.name
        case .transactionControl: return TransactionControlTool.name
        case .confirmDestructiveOperation: return ConfirmDestructiveOperationTool.name
        case .stopServerSession: return StopServerSessionTool.name
        case .connect: return ConnectTool.name
        case .disconnect: return DisconnectTool.name
        case .switchDatabase: return SwitchDatabaseTool.name
        case .switchSchema: return SwitchSchemaTool.name
        case .openConnectionWindow: return OpenConnectionWindowTool.name
        case .openTableTab: return OpenTableTabTool.name
        case .focusQueryTab: return FocusQueryTabTool.name
        }
    }

    // A read tool needs tools:write once its statement writes.
    var scopes: Set<MCPScope> {
        self == .confirmDestructiveOperation ? [.toolsWrite, .admin] : [.toolsWrite]
    }

    enum Reach: Sendable {
        case statement
        case session
        // The connection stays unsaved, so a call the gates pass stops at the tool's lookup before a window opens.
        case window
        // Names no connection: the tab list hides the ones the client may not reach. A hosted test has no window to raise.
        case tab
    }

    var reach: Reach {
        switch self {
        case .executeQuery, .explainQuery, .exportData, .insertRows, .createDatabase, .dropDatabaseObject,
             .runMaintenance, .transactionControl, .confirmDestructiveOperation, .stopServerSession:
            return .statement
        case .connect, .disconnect, .switchDatabase, .switchSchema:
            return .session
        case .openConnectionWindow, .openTableTab:
            return .window
        case .focusQueryTab:
            return .tab
        }
    }

    // Destructive, or documented in developers/mcp-tools.mdx as asking whatever Safe Mode says.
    var alwaysConfirms: Bool {
        switch self {
        case .createDatabase, .dropDatabaseObject, .runMaintenance, .confirmDestructiveOperation, .stopServerSession:
            return true
        default:
            return false
        }
    }

    // The hosted test's built-in metadata declares an analyzing explain only for CockroachDB, and MySQL
    // switches database on the live connection instead of opening another.
    var databaseType: DatabaseType {
        switch self {
        case .explainQuery: return .cockroachdb
        case .switchDatabase: return .mysql
        default: return .postgresql
        }
    }

    var driverReceives: String {
        switch self {
        case .executeQuery, .exportData: return Self.writeStatement
        case .explainQuery: return "EXPLAIN ANALYZE \(Self.writeStatement)"
        case .insertRows: return "INSERT INTO"
        case .createDatabase: return "CREATE DATABASE matrix_new"
        case .dropDatabaseObject: return "DROP DATABASE matrix_old"
        case .runMaintenance: return "VACUUM"
        case .transactionControl: return "BEGIN"
        case .confirmDestructiveOperation: return "DROP TABLE matrix_rows"
        case .stopServerSession: return "pg_cancel_backend(4242)"
        case .connect, .disconnect, .switchDatabase, .switchSchema, .openConnectionWindow, .openTableTab,
             .focusQueryTab:
            return ""
        }
    }

    func changed(_ session: ConnectionSession?) -> Bool {
        switch self {
        case .connect: return session != nil
        case .disconnect: return session == nil
        case .switchDatabase: return session?.browseDatabase == "matrix_other"
        case .switchSchema: return session?.browseSchema == "matrix_other"
        default: return false
        }
    }

    func arguments(connectionId: UUID, tabId: UUID) -> JsonValue {
        let connection: [String: JsonValue] = ["connection_id": .string(connectionId.uuidString)]
        let extra: [String: JsonValue]
        switch self {
        case .executeQuery:
            extra = ["query": .string(Self.writeStatement)]
        case .explainQuery:
            extra = ["query": .string(Self.writeStatement), "analyze": .bool(true)]
        case .exportData:
            extra = ["query": .string(Self.writeStatement), "format": .string("csv")]
        case .insertRows:
            extra = ["table": .string("matrix_rows"), "columns": .array([.string("id")]), "rows": .array([.array([.int(1)])])]
        case .createDatabase:
            extra = ["name": .string("matrix_new")]
        case .dropDatabaseObject:
            extra = ["kind": .string("database"), "name": .string("matrix_old")]
        case .runMaintenance:
            extra = ["operation": .string("VACUUM")]
        case .transactionControl:
            extra = ["action": .string("begin")]
        case .confirmDestructiveOperation:
            extra = ["query": .string("DROP TABLE matrix_rows")]
        case .stopServerSession:
            extra = ["process_id": .string("4242")]
        case .connect, .disconnect, .openConnectionWindow:
            extra = [:]
        case .switchDatabase:
            extra = ["database": .string("matrix_other")]
        case .switchSchema:
            extra = ["schema": .string("matrix_other")]
        case .openTableTab:
            extra = ["table_name": .string("matrix_rows")]
        case .focusQueryTab:
            return .object(["tab_id": .string(tabId.uuidString)])
        }
        return .object(connection.merging(extra) { first, _ in first })
    }

    // Each guard in the order a call meets it.
    static func expected(_ path: MCPWritePath, _ cell: MCPWriteCell) -> WriteOutcome {
        guard path.scopes.isSubset(of: cell.token.scopes) else { return .refused }
        guard cell.aiPolicy != .never, cell.externalAccess != .blocked else { return .refused }
        guard path.reach != .tab else { return .runs(after: []) }
        var prompts: [WritePrompt] = cell.aiPolicy == .askEachTime ? [.connectionAccess] : []
        guard path.reach == .statement else { return .runs(after: prompts) }
        guard cell.externalAccess == .readWrite, cell.safeMode != .readOnly else { return .refused }
        if path.alwaysConfirms || cell.safeMode.requiresConfirmation {
            prompts.append(.confirmation)
        }
        if cell.safeMode.requiresAuthentication {
            prompts.append(.authentication)
        }
        return .runs(after: prompts)
    }
}

struct AgentWriteCell: Sendable, CustomStringConvertible {
    let aiPolicy: AIConnectionPolicy
    let safeMode: SafeModeLevel
    let externalAccess: ExternalAccessLevel
    let alwaysAllowed: Bool

    var description: String {
        "AI \(aiPolicy.rawValue), Safe Mode \(safeMode.rawValue), external \(externalAccess.rawValue), "
            + (alwaysAllowed ? "always allowed" : "not always allowed")
    }

    static let all: [AgentWriteCell] = AIConnectionPolicy.allCases.flatMap { aiPolicy in
        SafeModeLevel.allCases.flatMap { safeMode in
            ExternalAccessLevel.allCases.flatMap { externalAccess in
                [false, true].map { alwaysAllowed in
                    AgentWriteCell(
                        aiPolicy: aiPolicy,
                        safeMode: safeMode,
                        externalAccess: externalAccess,
                        alwaysAllowed: alwaysAllowed
                    )
                }
            }
        }
    }
}

enum AgentWritePath: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case executeQuery
    case confirmDestructiveOperation
    case outsideServerTool

    static let builtIns: [AgentWritePath] = [.executeQuery, .confirmDestructiveOperation]

    var testDescription: String { rawValue }

    // The outside tool's name carries its server's id.
    var builtInName: String? {
        switch self {
        case .executeQuery: return ExecuteQueryChatTool().name
        case .confirmDestructiveOperation: return ConfirmDestructiveOperationChatTool().name
        case .outsideServerTool: return nil
        }
    }

    var input: JsonValue {
        switch self {
        case .executeQuery:
            return .object(["query": .string(MCPWritePath.writeStatement)])
        case .confirmDestructiveOperation:
            return .object([
                "query": .string("DROP TABLE matrix_rows"),
                "confirmation_phrase": .string(ConfirmDestructiveOperationChatTool.requiredPhrase)
            ])
        case .outsideServerTool:
            return .object(["ticket": .string("OPS-1")])
        }
    }

    var driverReceives: String {
        switch self {
        case .executeQuery: return MCPWritePath.writeStatement
        case .confirmDestructiveOperation: return "DROP TABLE matrix_rows"
        case .outsideServerTool: return ""
        }
    }

    // External Clients governs MCP and AppleScript, never the assistant.
    static func expected(_ path: AgentWritePath, _ cell: AgentWriteCell) -> WriteOutcome {
        guard cell.aiPolicy != .never else { return .refused }
        var prompts: [WritePrompt] = cell.aiPolicy == .askEachTime ? [.connectionAccess] : []
        guard path != .outsideServerTool else { return .runs(after: prompts + [.toolCard]) }
        guard cell.safeMode != .readOnly else { return .refused }
        let destructive = path == .confirmDestructiveOperation
        // Silent and an Always Allow grant skip the card for a write, never for a destructive one.
        let showsCard = destructive || (!cell.alwaysAllowed && cell.safeMode != .silent)
        if showsCard {
            prompts.append(.toolCard)
        } else if cell.safeMode.requiresConfirmation {
            prompts.append(.confirmation)
        }
        if cell.safeMode.requiresAuthentication {
            prompts.append(.authentication)
        }
        return .runs(after: prompts)
    }
}
