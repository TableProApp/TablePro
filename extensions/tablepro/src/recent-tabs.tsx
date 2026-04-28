import {
    Action,
    ActionPanel,
    Icon,
    List,
    showToast,
    Toast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { RecentTab } from "./lib/types";
import { listRecentTabs, openConnectionWindow } from "./lib/mcp";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";
import { openTableDeeplink } from "./lib/deeplink";

export default function RecentTabsCommand() {
    const [tabs, setTabs] = useState<RecentTab[] | null>(null);
    const [error, setError] = useState<unknown>(null);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                const list = await listRecentTabs();
                if (!cancelled) setTabs(list);
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
            isLoading={tabs === null}
            searchBarPlaceholder="Filter recent tabs"
        >
            {tabs !== null && tabs.length === 0 ? (
                <List.EmptyView
                    icon={Icon.Clock}
                    title="No recent tabs"
                    description="Open a tab in TablePro to see it here."
                />
            ) : null}
            {(tabs ?? []).map((tab) => (
                <List.Item
                    key={tab.id}
                    title={tab.title}
                    subtitle={tab.connectionName}
                    icon={tabIcon(tab)}
                    accessories={[{ tag: tab.tabType }]}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open in TablePro"
                                icon={Icon.AppWindow}
                                onAction={async () => {
                                    try {
                                        if (tab.tableName) {
                                            await openTableDeeplink(
                                                tab.connectionId,
                                                tab.tableName,
                                                tab.databaseName,
                                            );
                                        } else {
                                            await openConnectionWindow(
                                                tab.connectionId,
                                            );
                                        }
                                    } catch (err) {
                                        await showToast({
                                            style: Toast.Style.Failure,
                                            title: "Failed to open tab",
                                            message:
                                                err instanceof Error
                                                    ? err.message
                                                    : String(err),
                                        });
                                    }
                                }}
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}

function tabIcon(tab: RecentTab): Icon {
    switch (tab.tabType) {
        case "query":
            return Icon.Terminal;
        case "table":
            return Icon.List;
        case "structure":
            return Icon.Code;
        default:
            return Icon.Document;
    }
}
