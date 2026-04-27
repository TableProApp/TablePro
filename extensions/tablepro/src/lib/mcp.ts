import { promises as fs } from "fs";
import {
    ColumnInfo,
    Connection,
    DatabaseInfo,
    MCPHandshake,
    MCPNotRunningError,
    QueryHistoryEntry,
    QueryResult,
    RecentTab,
    SchemaInfo,
    TableInfo,
    TableProNotInstalledError,
    TokenMissingError,
    TokenRevokedError,
    ExternalAccessDeniedError,
    Preferences,
} from "./types";
import { handshakeFilePath, tableProInstalled } from "./paths";
import { startMCPDeeplink } from "./deeplink";
import { getPreferenceValues } from "@raycast/api";

interface JsonRpcRequest {
    jsonrpc: "2.0";
    id: string;
    method: string;
    params?: unknown;
}

interface JsonRpcSuccess<T> {
    jsonrpc: "2.0";
    id: string;
    result: T;
}

interface JsonRpcError {
    jsonrpc: "2.0";
    id: string;
    error: {
        code: number;
        message: string;
        data?: unknown;
    };
}

type JsonRpcResponse<T> = JsonRpcSuccess<T> | JsonRpcError;

async function readHandshake(): Promise<MCPHandshake | null> {
    try {
        const raw = await fs.readFile(handshakeFilePath(), "utf8");
        const parsed = JSON.parse(raw) as MCPHandshake;
        if (
            typeof parsed.port !== "number" ||
            typeof parsed.token !== "string"
        ) {
            return null;
        }
        return parsed;
    } catch {
        return null;
    }
}

const HANDSHAKE_RETRY_DELAY_MS = 600;
const HANDSHAKE_MAX_RETRIES = 12;

async function ensureHandshake(allowAutoStart: boolean): Promise<MCPHandshake> {
    if (!tableProInstalled()) {
        throw new TableProNotInstalledError();
    }
    let handshake = await readHandshake();
    if (handshake) return handshake;
    if (!allowAutoStart) {
        throw new MCPNotRunningError();
    }
    await startMCPDeeplink();
    for (let attempt = 0; attempt < HANDSHAKE_MAX_RETRIES; attempt += 1) {
        await new Promise((resolve) =>
            setTimeout(resolve, HANDSHAKE_RETRY_DELAY_MS),
        );
        handshake = await readHandshake();
        if (handshake) return handshake;
    }
    throw new MCPNotRunningError();
}

function getApiToken(): string {
    const prefs = getPreferenceValues<Preferences>();
    if (!prefs.apiToken || prefs.apiToken.trim() === "") {
        throw new TokenMissingError();
    }
    return prefs.apiToken.trim();
}

let requestCounter = 0;
function nextRequestId(): string {
    requestCounter += 1;
    return `tp-${Date.now()}-${requestCounter}`;
}

async function rpc<T>(
    method: string,
    params: Record<string, unknown> = {},
): Promise<T> {
    const handshake = await ensureHandshake(true);
    const token = getApiToken();
    const url = `http${handshake.tls ? "s" : ""}://127.0.0.1:${handshake.port}/v1/mcp`;
    const body: JsonRpcRequest = {
        jsonrpc: "2.0",
        id: nextRequestId(),
        method,
        params,
    };
    let response: Response;
    try {
        response = await fetch(url, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${token}`,
            },
            body: JSON.stringify(body),
        });
    } catch {
        throw new MCPNotRunningError();
    }
    if (response.status === 401) {
        throw new TokenRevokedError();
    }
    if (response.status === 403) {
        const message = await safeReadError(response);
        throw new ExternalAccessDeniedError(message);
    }
    if (!response.ok) {
        throw new Error(`TablePro MCP returned HTTP ${response.status}`);
    }
    const json = (await response.json()) as JsonRpcResponse<T>;
    if ("error" in json) {
        const message = json.error.message;
        if (
            message.toLowerCase().includes("read-only") ||
            message.toLowerCase().includes("read only")
        ) {
            throw new ExternalAccessDeniedError(message);
        }
        throw new Error(message);
    }
    return json.result;
}

async function safeReadError(response: Response): Promise<string> {
    try {
        const text = await response.text();
        return text || `HTTP ${response.status}`;
    } catch {
        return `HTTP ${response.status}`;
    }
}

export async function callTool<T>(
    name: string,
    args: Record<string, unknown> = {},
): Promise<T> {
    const result = await rpc<{
        content: Array<{ type: string; text?: string; data?: unknown }>;
    }>("tools/call", {
        name,
        arguments: args,
    });
    const first = result.content?.[0];
    if (!first) {
        return undefined as T;
    }
    if (first.data !== undefined) {
        return first.data as T;
    }
    if (first.text !== undefined) {
        try {
            return JSON.parse(first.text) as T;
        } catch {
            return first.text as unknown as T;
        }
    }
    return undefined as T;
}

export async function listConnections(): Promise<Connection[]> {
    return callTool<Connection[]>("list_connections");
}

export async function listDatabases(
    connectionId: string,
): Promise<DatabaseInfo[]> {
    return callTool<DatabaseInfo[]>("list_databases", {
        connection_id: connectionId,
    });
}

export async function listSchemas(
    connectionId: string,
    database?: string,
): Promise<SchemaInfo[]> {
    return callTool<SchemaInfo[]>("list_schemas", {
        connection_id: connectionId,
        database,
    });
}

export async function listTables(
    connectionId: string,
    options: { database?: string; schema?: string } = {},
): Promise<TableInfo[]> {
    return callTool<TableInfo[]>("list_tables", {
        connection_id: connectionId,
        database: options.database,
        schema: options.schema,
    });
}

export async function describeTable(
    connectionId: string,
    table: string,
    options: { database?: string; schema?: string } = {},
): Promise<{ columns: ColumnInfo[] }> {
    return callTool<{ columns: ColumnInfo[] }>("describe_table", {
        connection_id: connectionId,
        table,
        database: options.database,
        schema: options.schema,
    });
}

export async function getTableDDL(
    connectionId: string,
    table: string,
    options: { database?: string; schema?: string } = {},
): Promise<{ ddl: string }> {
    return callTool<{ ddl: string }>("get_table_ddl", {
        connection_id: connectionId,
        table,
        database: options.database,
        schema: options.schema,
    });
}

export async function executeQuery(
    connectionId: string,
    sql: string,
    options: { database?: string; schema?: string; rowLimit?: number } = {},
): Promise<QueryResult> {
    return callTool<QueryResult>("execute_query", {
        connection_id: connectionId,
        sql,
        database: options.database,
        schema: options.schema,
        row_limit: options.rowLimit,
    });
}

export async function explainQuery(
    connectionId: string,
    sql: string,
    options: { database?: string; schema?: string } = {},
): Promise<QueryResult> {
    return callTool<QueryResult>("execute_query", {
        connection_id: connectionId,
        sql: `EXPLAIN ${sql}`,
        database: options.database,
        schema: options.schema,
    });
}

export async function listRecentTabs(): Promise<RecentTab[]> {
    return callTool<RecentTab[]>("list_recent_tabs");
}

export async function searchHistory(
    query: string,
    limit = 50,
): Promise<QueryHistoryEntry[]> {
    return callTool<QueryHistoryEntry[]>("search_query_history", {
        query,
        limit,
    });
}

export async function openConnectionWindow(
    connectionId: string,
): Promise<void> {
    await callTool<void>("open_connection_window", {
        connection_id: connectionId,
    });
}

export async function exchangePairingCode(
    code: string,
    codeVerifier: string,
): Promise<{ token: string }> {
    const handshake = await ensureHandshake(false);
    const url = `http${handshake.tls ? "s" : ""}://127.0.0.1:${handshake.port}/v1/integrations/exchange`;
    const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code, code_verifier: codeVerifier }),
    });
    if (!response.ok) {
        const text = await safeReadError(response);
        throw new Error(`Pairing exchange failed: ${text}`);
    }
    const json = (await response.json()) as { token?: string };
    if (!json.token) {
        throw new Error("Pairing exchange returned no token");
    }
    return { token: json.token };
}
