import {
    Action,
    ActionPanel,
    Icon,
    List,
    showToast,
    Toast,
    Clipboard,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { Connection, TableProNotInstalledError } from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { tableProInstalled } from "./lib/paths";
import { openConnectionDeeplink } from "./lib/deeplink";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";

export default function SearchConnections() {
    const [connections, setConnections] = useState<Connection[] | null>(null);
    const [error, setError] = useState<unknown>(null);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                if (!tableProInstalled()) {
                    throw new TableProNotInstalledError();
                }
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

    const grouped = groupByType(connections ?? []);

    return (
        <List
            isLoading={connections === null}
            searchBarPlaceholder="Filter connections by name, host, or type"
        >
            {connections !== null && connections.length === 0 ? (
                <List.EmptyView
                    icon={Icon.Plug}
                    title="No connections yet"
                    description="Add a connection in TablePro to see it here."
                />
            ) : null}
            {Object.entries(grouped).map(([type, items]) => (
                <List.Section
                    key={type}
                    title={databaseTypeLabel(type)}
                    subtitle={`${items.length}`}
                >
                    {items.map((connection) => (
                        <ConnectionRow
                            key={connection.id}
                            connection={connection}
                        />
                    ))}
                </List.Section>
            ))}
        </List>
    );
}

function ConnectionRow({ connection }: { connection: Connection }) {
    const subtitle = formatSubtitle(connection);
    return (
        <List.Item
            title={connection.name}
            subtitle={subtitle}
            accessories={[{ tag: databaseTypeLabel(connection.type) }]}
            icon={Icon.HardDrive}
            actions={
                <ActionPanel>
                    <Action
                        title="Open in TablePro"
                        icon={Icon.AppWindow}
                        onAction={async () => {
                            try {
                                await openConnectionDeeplink(connection.id);
                            } catch (err) {
                                await showToast({
                                    style: Toast.Style.Failure,
                                    title: "Failed to open connection",
                                    message:
                                        err instanceof Error
                                            ? err.message
                                            : String(err),
                                });
                            }
                        }}
                    />
                    <Action
                        title="Copy Deep Link"
                        icon={Icon.Link}
                        shortcut={{ modifiers: ["cmd"], key: "." }}
                        onAction={async () => {
                            await Clipboard.copy(
                                `tablepro://connect/${connection.id}`,
                            );
                            await showToast({
                                style: Toast.Style.Success,
                                title: "Deep link copied",
                            });
                        }}
                    />
                    <Action.CopyToClipboard
                        title="Copy Connection ID"
                        content={connection.id}
                        shortcut={{ modifiers: ["cmd", "shift"], key: "." }}
                    />
                </ActionPanel>
            }
        />
    );
}

function formatSubtitle(connection: Connection): string {
    if (!connection.host) return "";
    if (connection.port) return `${connection.host}:${connection.port}`;
    return connection.host;
}

function groupByType(list: Connection[]): Record<string, Connection[]> {
    const map: Record<string, Connection[]> = {};
    for (const conn of list) {
        const bucket = map[conn.type] ?? [];
        bucket.push(conn);
        map[conn.type] = bucket;
    }
    return map;
}
