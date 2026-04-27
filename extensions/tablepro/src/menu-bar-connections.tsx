import {
    Icon,
    MenuBarExtra,
    launchCommand,
    LaunchType,
    open,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { Connection } from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { tableProInstalled } from "./lib/paths";
import { openConnectionDeeplink } from "./lib/deeplink";

const MAX_RECENT = 12;

export default function MenuBarConnections() {
    const [connections, setConnections] = useState<Connection[] | null>(null);
    const [installed, setInstalled] = useState<boolean>(true);

    useEffect(() => {
        (async () => {
            const present = tableProInstalled();
            setInstalled(present);
            if (!present) {
                setConnections([]);
                return;
            }
            try {
                const list = await loadConnections();
                setConnections(list);
            } catch {
                setConnections([]);
            }
        })();
    }, []);

    const isLoading = connections === null;
    const recent = (connections ?? []).slice(0, MAX_RECENT);

    return (
        <MenuBarExtra
            icon={Icon.HardDrive}
            isLoading={isLoading}
            tooltip="TablePro"
        >
            {!installed ? (
                <MenuBarExtra.Item
                    title="Install TablePro"
                    icon={Icon.Download}
                    onAction={() => open("https://tablepro.app")}
                />
            ) : null}
            {installed && recent.length > 0 ? (
                <MenuBarExtra.Section title="Connections">
                    {recent.map((connection) => (
                        <MenuBarExtra.Item
                            key={connection.id}
                            title={connection.name}
                            subtitle={databaseTypeLabel(connection.type)}
                            onAction={() =>
                                openConnectionDeeplink(connection.id)
                            }
                        />
                    ))}
                </MenuBarExtra.Section>
            ) : null}
            {installed && recent.length === 0 ? (
                <MenuBarExtra.Item title="No connections yet" />
            ) : null}
            <MenuBarExtra.Section>
                <MenuBarExtra.Item
                    title="Search Connections"
                    icon={Icon.MagnifyingGlass}
                    onAction={() =>
                        launchCommand({
                            name: "search-connections",
                            type: LaunchType.UserInitiated,
                        })
                    }
                />
                <MenuBarExtra.Item
                    title="Recent Tabs"
                    icon={Icon.Clock}
                    onAction={() =>
                        launchCommand({
                            name: "recent-tabs",
                            type: LaunchType.UserInitiated,
                        })
                    }
                />
                <MenuBarExtra.Item
                    title="Run Query"
                    icon={Icon.Terminal}
                    onAction={() =>
                        launchCommand({
                            name: "run-query",
                            type: LaunchType.UserInitiated,
                        })
                    }
                />
            </MenuBarExtra.Section>
        </MenuBarExtra>
    );
}
