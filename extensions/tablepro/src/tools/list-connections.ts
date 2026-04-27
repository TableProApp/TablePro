import { Connection } from "../lib/types";
import { loadConnections } from "../lib/connections";
import { listConnections } from "../lib/mcp";

/**
 * List all saved TablePro connections. Reads connections.json directly when no
 * token is paired so the model can still discover what is available.
 */
export default async function tool(): Promise<Connection[]> {
    try {
        return await listConnections();
    } catch {
        return loadConnections();
    }
}
