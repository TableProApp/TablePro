import {
    Action,
    ActionPanel,
    Form,
    Icon,
    List,
    Detail,
    useNavigation,
    showToast,
    Toast,
    confirmAlert,
    Alert,
    getPreferenceValues,
} from "@raycast/api";
import { useEffect, useState } from "react";
import {
    Connection,
    Preferences,
    QueryResult,
    TableProNotInstalledError,
} from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { tableProInstalled } from "./lib/paths";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";
import { executeQuery } from "./lib/mcp";
import { openQueryDeeplink } from "./lib/deeplink";
import { isMutatingSQL, summarizeSQL } from "./lib/sql";

export default function RunQueryCommand() {
    const [connections, setConnections] = useState<Connection[] | null>(null);
    const [error, setError] = useState<unknown>(null);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                if (!tableProInstalled()) throw new TableProNotInstalledError();
                const list = await loadConnections();
                if (!cancelled) setConnections(list);
            } catch (err) {
                if (!cancelled) setError(err);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, []);

    if (error) {
        return (
            <List>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    if (connections === null) {
        return <List isLoading />;
    }

    if (connections.length === 0) {
        return (
            <List>
                <List.EmptyView
                    icon={Icon.Plug}
                    title="No connections yet"
                    description="Add a connection in TablePro before running queries."
                />
            </List>
        );
    }

    return <QueryForm connections={connections} />;
}

function QueryForm({ connections }: { connections: Connection[] }) {
    const initialId = connections[0]?.id ?? "";
    const [connectionId, setConnectionId] = useState<string>(initialId);
    const [sql, setSql] = useState<string>("");
    const { push } = useNavigation();

    return (
        <Form
            actions={
                <ActionPanel>
                    <Action.SubmitForm
                        title="Run Query"
                        icon={Icon.Play}
                        onSubmit={async (values: {
                            connection: string;
                            sql: string;
                        }) => {
                            const trimmed = values.sql.trim();
                            if (!trimmed) {
                                await showToast({
                                    style: Toast.Style.Failure,
                                    title: "SQL is empty",
                                });
                                return;
                            }
                            const target = connections.find(
                                (c) => c.id === values.connection,
                            );
                            if (!target) {
                                await showToast({
                                    style: Toast.Style.Failure,
                                    title: "Pick a connection",
                                });
                                return;
                            }
                            if (isMutatingSQL(trimmed)) {
                                const confirmed = await confirmAlert({
                                    title: "Run mutating query?",
                                    message: summarizeSQL(trimmed),
                                    primaryAction: {
                                        title: "Run",
                                        style: Alert.ActionStyle.Destructive,
                                    },
                                });
                                if (!confirmed) return;
                            }
                            push(
                                <RunningView
                                    connection={target}
                                    sql={trimmed}
                                />,
                            );
                        }}
                    />
                    <Action.SubmitForm
                        title="Open Query in TablePro"
                        icon={Icon.AppWindow}
                        onSubmit={async (values: {
                            connection: string;
                            sql: string;
                        }) => {
                            const target = connections.find(
                                (c) => c.id === values.connection,
                            );
                            if (!target) return;
                            const prefs = getPreferenceValues<Preferences>();
                            await openQueryDeeplink(
                                target.id,
                                values.sql,
                                prefs.apiToken,
                            );
                        }}
                    />
                </ActionPanel>
            }
        >
            <Form.Dropdown
                id="connection"
                title="Connection"
                value={connectionId}
                onChange={setConnectionId}
            >
                {connections.map((connection) => (
                    <Form.Dropdown.Item
                        key={connection.id}
                        value={connection.id}
                        title={connection.name}
                        keywords={[
                            connection.host ?? "",
                            databaseTypeLabel(connection.type),
                        ]}
                    />
                ))}
            </Form.Dropdown>
            <Form.TextArea
                id="sql"
                title="SQL"
                placeholder="SELECT * FROM users LIMIT 100"
                value={sql}
                onChange={setSql}
            />
            <Form.Description text="Mutating queries (INSERT, UPDATE, DELETE, etc.) ask for confirmation before running. The connection's external-access setting may still reject them." />
        </Form>
    );
}

function RunningView({
    connection,
    sql,
}: {
    connection: Connection;
    sql: string;
}) {
    const [result, setResult] = useState<QueryResult | null>(null);
    const [error, setError] = useState<unknown>(null);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                const data = await executeQuery(connection.id, sql, {
                    rowLimit: 200,
                });
                if (!cancelled) setResult(data);
            } catch (err) {
                if (!cancelled) setError(err);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [connection.id, sql]);

    if (error) {
        return (
            <List>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    if (!result) {
        return (
            <Detail
                isLoading
                markdown={`Running on **${connection.name}**…\n\n\`\`\`sql\n${sql}\n\`\`\``}
            />
        );
    }

    return <ResultView connection={connection} sql={sql} result={result} />;
}

function ResultView({
    connection,
    sql,
    result,
}: {
    connection: Connection;
    sql: string;
    result: QueryResult;
}) {
    if (result.error) {
        return (
            <Detail
                markdown={`# Query failed\n\n${result.error}\n\n\`\`\`sql\n${sql}\n\`\`\``}
                actions={
                    <ActionPanel>
                        <Action
                            title="Open in TablePro"
                            icon={Icon.AppWindow}
                            onAction={() =>
                                openQueryDeeplink(connection.id, sql)
                            }
                        />
                    </ActionPanel>
                }
            />
        );
    }

    if (!result.rows || result.rows.length === 0) {
        const summary =
            result.affectedRows !== undefined
                ? `${result.affectedRows} rows affected`
                : "Query returned no rows";
        return (
            <Detail
                markdown={`# ${summary}\n\nDuration: ${result.durationMs ?? 0} ms\n\n\`\`\`sql\n${sql}\n\`\`\``}
                actions={
                    <ActionPanel>
                        <Action
                            title="Open in TablePro"
                            icon={Icon.AppWindow}
                            onAction={() =>
                                openQueryDeeplink(connection.id, sql)
                            }
                        />
                    </ActionPanel>
                }
            />
        );
    }

    const markdown = renderResultMarkdown(connection.name, sql, result);
    return (
        <Detail
            markdown={markdown}
            actions={
                <ActionPanel>
                    <Action
                        title="Open in TablePro"
                        icon={Icon.AppWindow}
                        onAction={() => openQueryDeeplink(connection.id, sql)}
                    />
                    <Action.CopyToClipboard title="Copy SQL" content={sql} />
                </ActionPanel>
            }
        />
    );
}

function renderResultMarkdown(
    connectionName: string,
    sql: string,
    result: QueryResult,
): string {
    const headerRow = `| ${result.columns.join(" | ")} |`;
    const separator = `| ${result.columns.map(() => "---").join(" | ")} |`;
    const dataRows = result.rows.slice(0, 50).map((row) => {
        return `| ${result.columns.map((col) => formatCell(row[col])).join(" | ")} |`;
    });
    const previewNote =
        result.rows.length > 50
            ? `\n\n_Showing 50 of ${result.rows.length} rows. Open in TablePro for the full grid._`
            : "";
    return [
        `# ${connectionName}`,
        `${result.rows.length} rows in ${result.durationMs ?? 0} ms`,
        "",
        "```sql",
        sql,
        "```",
        "",
        headerRow,
        separator,
        ...dataRows,
        previewNote,
    ].join("\n");
}

function formatCell(value: unknown): string {
    if (value === null || value === undefined) return "_null_";
    if (typeof value === "string")
        return value.replace(/\|/g, "\\|").slice(0, 120);
    if (typeof value === "number" || typeof value === "boolean")
        return String(value);
    try {
        return JSON.stringify(value).slice(0, 120);
    } catch {
        return "_unprintable_";
    }
}
