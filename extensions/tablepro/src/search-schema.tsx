import { Action, ActionPanel, Icon, List, useNavigation } from "@raycast/api";
import { useEffect, useState } from "react";
import { Connection, DatabaseInfo, SchemaInfo } from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { listDatabases, listSchemas, listTables } from "./lib/mcp";
import { tableProInstalled } from "./lib/paths";
import { TableProNotInstalledError } from "./lib/types";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";
import SearchTablesView from "./search-tables";

export default function SearchSchema() {
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

    return (
        <List
            isLoading={connections === null}
            searchBarPlaceholder="Pick a connection"
        >
            {connections !== null && connections.length === 0 ? (
                <List.EmptyView
                    icon={Icon.Plug}
                    title="No connections yet"
                    description="Add a connection in TablePro to browse its schema."
                />
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
                            <Action.Push
                                title="Browse Schema"
                                target={
                                    <DatabasesView connection={connection} />
                                }
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}

function DatabasesView({ connection }: { connection: Connection }) {
    const [databases, setDatabases] = useState<DatabaseInfo[] | null>(null);
    const [error, setError] = useState<unknown>(null);
    const { push } = useNavigation();

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                const list = await listDatabases(connection.id);
                if (!cancelled) setDatabases(list);
            } catch (err) {
                if (!cancelled) setError(err);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [connection.id]);

    if (error) {
        return (
            <List navigationTitle={connection.name}>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    return (
        <List
            isLoading={databases === null}
            navigationTitle={connection.name}
            searchBarPlaceholder="Filter databases"
        >
            {databases !== null && databases.length === 0 ? (
                <List.EmptyView icon={Icon.HardDrive} title="No databases" />
            ) : null}
            {(databases ?? []).map((db) => (
                <List.Item
                    key={db.name}
                    title={db.name}
                    icon={Icon.HardDrive}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open Schemas"
                                icon={Icon.Folder}
                                onAction={() =>
                                    push(
                                        <SchemasView
                                            connection={connection}
                                            database={db.name}
                                        />,
                                    )
                                }
                            />
                            <Action
                                title="Browse Tables"
                                icon={Icon.List}
                                onAction={() =>
                                    push(
                                        <SearchTablesView
                                            connection={connection}
                                            database={db.name}
                                        />,
                                    )
                                }
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}

function SchemasView({
    connection,
    database,
}: {
    connection: Connection;
    database: string;
}) {
    const [schemas, setSchemas] = useState<SchemaInfo[] | null>(null);
    const [error, setError] = useState<unknown>(null);
    const { push } = useNavigation();

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                const list = await listSchemas(connection.id, database);
                if (!cancelled) setSchemas(list);
            } catch (err) {
                if (!cancelled) setError(err);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [connection.id, database]);

    if (error) {
        return (
            <List navigationTitle={`${connection.name} / ${database}`}>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    return (
        <List
            isLoading={schemas === null}
            navigationTitle={`${connection.name} / ${database}`}
            searchBarPlaceholder="Filter schemas"
        >
            {schemas !== null && schemas.length === 0 ? (
                <List.EmptyView icon={Icon.Folder} title="No schemas" />
            ) : null}
            {(schemas ?? []).map((schema) => (
                <List.Item
                    key={schema.name}
                    title={schema.name}
                    icon={Icon.Folder}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Browse Tables"
                                icon={Icon.List}
                                onAction={async () => {
                                    await listTables(connection.id, {
                                        database,
                                        schema: schema.name,
                                    });
                                    push(
                                        <SearchTablesView
                                            connection={connection}
                                            database={database}
                                            schema={schema.name}
                                        />,
                                    );
                                }}
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}
