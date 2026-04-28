import { homedir } from "os";
import { join } from "path";
import { getPreferenceValues } from "@raycast/api";
import { existsSync } from "fs";
import { Preferences } from "./types";

const CONNECTION_SUPPORT_RELATIVE = "Library/Application Support/TablePro";
const MCP_SUPPORT_RELATIVE = "Library/Application Support/com.TablePro";

export function connectionSupportDir(): string {
    return join(homedir(), CONNECTION_SUPPORT_RELATIVE);
}

export function mcpSupportDir(): string {
    return join(homedir(), MCP_SUPPORT_RELATIVE);
}

export function connectionsFilePath(): string {
    return join(connectionSupportDir(), "connections.json");
}

export function handshakeFilePath(): string {
    return join(mcpSupportDir(), "mcp-handshake.json");
}

export function tableProAppPath(): string {
    const prefs = getPreferenceValues<Preferences>();
    const value = prefs.tableProAppPath;
    if (!value) {
        return "/Applications/TablePro.app";
    }
    if (typeof value === "string") {
        return value;
    }
    return value.path ?? "/Applications/TablePro.app";
}

export function tableProInstalled(): boolean {
    return existsSync(tableProAppPath());
}
