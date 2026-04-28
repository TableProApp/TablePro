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
import { useCachedPromise } from "@raycast/utils";
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
    const {
        data: connections,
        isLoading,
        error,
    } = useCachedPromise(
        async () => {
            if (!tableProInstalled()) throw new TableProNotInstalledError();
            return loadConnections();
        },
        [],
        { keepPreviousData: true },
    );
    const { push } = useNavigation();

    if (error) {
        return (
            <List>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    return (
        <List isLoading={isLoading} searchBarPlaceholder="Pick a connection">
            {!isLoading &&
            connections !== undefined &&
            connections.length === 0 ? (
                <List.EmptyView
                    icon={Icon.Plug}
                    title="No connections yet"
                    description="Add a connection in TablePro to browse its tables."
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
    const {
        data: tables,
        isLoading,
        error,
    } = useCachedPromise(
        (id: string, db: string | undefined, sc: string | undefined) =>
            listTables(id, { database: db, schema: sc }),
        [connection.id, database, schema],
        { keepPreviousData: true },
    );

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
            isLoading={isLoading}
            navigationTitle={navTitle}
            searchBarPlaceholder="Filter tables"
        >
            {!isLoading && tables !== undefined && tables.length === 0 ? (
                <List.EmptyView
                    icon={Icon.List}
                    title="No tables"
                    description="This connection has no tables in the selected scope."
                />
            ) : null}
            {(tables ?? []).map((table) => (
                <List.Item
                    key={`${table.schema ?? ""}.${table.name}`}
                    title={table.name}
                    subtitle={table.schema}
                    accessories={tableAccessories(table)}
                    icon={Icon.List}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open Table in TablePro"
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
                                title="Copy DDL"
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

function tableAccessories(table: TableInfo): List.Item.Accessory[] {
    const accessories: List.Item.Accessory[] = [];
    if (table.type && table.type.toLowerCase() !== "table") {
        accessories.push({ tag: table.type });
    }
    if (table.rowCount !== undefined) {
        accessories.push({ text: `${table.rowCount} rows` });
    }
    return accessories;
}
