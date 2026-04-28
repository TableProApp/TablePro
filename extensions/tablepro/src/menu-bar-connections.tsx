import {
    Icon,
    MenuBarExtra,
    launchCommand,
    LaunchType,
    open,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { Connection } from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { tableProInstalled } from "./lib/paths";
import { openConnectionDeeplink } from "./lib/deeplink";

const MAX_RECENT = 12;

interface MenuData {
    installed: boolean;
    connections: Connection[];
}

export default function MenuBarConnections() {
    const { data, isLoading } = useCachedPromise(
        async (): Promise<MenuData> => {
            const installed = tableProInstalled();
            if (!installed) {
                return { installed: false, connections: [] };
            }
            try {
                const list = await loadConnections();
                return { installed: true, connections: list };
            } catch {
                return { installed: true, connections: [] };
            }
        },
        [],
        { keepPreviousData: true },
    );

    const installed = data?.installed ?? true;
    const recent = (data?.connections ?? []).slice(0, MAX_RECENT);

    return (
        <MenuBarExtra
            icon={Icon.HardDrive}
            isLoading={isLoading}
            tooltip="TablePro"
        >
            {!installed ? (
                <MenuBarExtra.Section>
                    <MenuBarExtra.Item
                        title="Install TablePro"
                        icon={Icon.Download}
                        onAction={() =>
                            open("https://tablepro.app").catch(() => undefined)
                        }
                    />
                </MenuBarExtra.Section>
            ) : null}
            {installed && recent.length > 0 ? (
                <MenuBarExtra.Section title="Connections">
                    {recent.map((connection) => (
                        <MenuBarExtra.Item
                            key={connection.id}
                            title={connection.name}
                            subtitle={databaseTypeLabel(connection.type)}
                            onAction={() =>
                                openConnectionDeeplink(connection.id).catch(
                                    () => undefined,
                                )
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
