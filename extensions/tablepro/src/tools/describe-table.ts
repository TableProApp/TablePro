import { ColumnInfo } from "../lib/types";
import { describeTable } from "../lib/mcp";

type Input = {
    /** UUID of the TablePro connection. */
    connectionId: string;
    /** Table name. */
    table: string;
    /** Database name. Optional. */
    database?: string;
    /** Schema name. Optional. */
    schema?: string;
};

export default async function tool(
    input: Input,
): Promise<{ columns: ColumnInfo[] }> {
    return describeTable(input.connectionId, input.table, {
        database: input.database,
        schema: input.schema,
    });
}
