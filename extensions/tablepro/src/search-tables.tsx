import {
    Action,
    ActionPanel,
    Clipboard,
    Icon,
    List,
    showToast,
    Toast,
    useNavigation,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { Connection, TableInfo } from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { listTables, getTableDDL } from "./lib/mcp";
import { tableProInstalled } from "./lib/paths";
import { TableProNotInstalledError } from "./lib/types";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";
import { openTableDeeplink } from "./lib/deeplink";

interface Props {
    connection?: Connection;
    database?: string;
    schema?: string;
}

export default function SearchTables(props: Props) {
    if (!props.connection) {
        return <ConnectionPicker />;
    }
    return (
        <TablesList
            connection={props.connection}
            database={props.database}
            schema={props.schema}
        />
    );
}

function ConnectionPicker() {
    const [connections, setConnections] = useState<Connection[] | null>(null);
    const [error, setError] = useState<unknown>(null);
    const { push } = useNavigation();

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

    return (
        <List
            isLoading={connections === null}
            searchBarPlaceholder="Pick a connection"
        >
            {connections !== null && connections.length === 0 ? (
                <List.EmptyView icon={Icon.Plug} title="No connections yet" />
            ) : null}
            {(connections ?? []).map((connection) => (
                <List.Item
                    key={connection.id}
                    title={connection.name}
                    subtitle={connection.host}
                    accessories={[{ tag: databaseTypeLabel(connection.type) }]}
                    icon={Icon.HardDrive}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Browse Tables"
                                onAction={() =>
                                    push(<TablesList connection={connection} />)
                                }
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}

function TablesList({
    connection,
    database,
    schema,
}: {
    connection: Connection;
    database?: string;
    schema?: string;
}) {
    const [tables, setTables] = useState<TableInfo[] | null>(null);
    const [error, setError] = useState<unknown>(null);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                const list = await listTables(connection.id, {
                    database,
                    schema,
                });
                if (!cancelled) setTables(list);
            } catch (err) {
                if (!cancelled) setError(err);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [connection.id, database, schema]);

    if (error) {
        return (
            <List navigationTitle={connection.name}>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    const navTitle = [connection.name, database, schema]
        .filter(Boolean)
        .join(" / ");

    return (
        <List
            isLoading={tables === null}
            navigationTitle={navTitle}
            searchBarPlaceholder="Filter tables"
        >
            {tables !== null && tables.length === 0 ? (
                <List.EmptyView icon={Icon.List} title="No tables" />
            ) : null}
            {(tables ?? []).map((table) => (
                <List.Item
                    key={`${table.schema ?? ""}.${table.name}`}
                    title={table.name}
                    subtitle={table.schema}
                    accessories={
                        table.rowCount !== undefined
                            ? [{ text: `${table.rowCount} rows` }]
                            : undefined
                    }
                    icon={Icon.List}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open Table in Tablepro"
                                icon={Icon.AppWindow}
                                onAction={async () => {
                                    await openTableDeeplink(
                                        connection.id,
                                        table.name,
                                        database,
                                        table.schema ?? schema,
                                    );
                                }}
                            />
                            <Action
                                title="Copy Create Statement"
                                icon={Icon.Code}
                                shortcut={{ modifiers: ["cmd"], key: "d" }}
                                onAction={async () => {
                                    try {
                                        const result = await getTableDDL(
                                            connection.id,
                                            table.name,
                                            {
                                                schema: table.schema ?? schema,
                                            },
                                        );
                                        await Clipboard.copy(result.ddl);
                                        await showToast({
                                            style: Toast.Style.Success,
                                            title: "DDL copied",
                                        });
                                    } catch (err) {
                                        await showToast({
                                            style: Toast.Style.Failure,
                                            title: "Failed to fetch DDL",
                                            message:
                                                err instanceof Error
                                                    ? err.message
                                                    : String(err),
                                        });
                                    }
                                }}
                            />
                            <Action.CopyToClipboard
                                title="Copy Table Name"
                                content={table.name}
                                shortcut={{
                                    modifiers: ["cmd", "shift"],
                                    key: "c",
                                }}
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}
