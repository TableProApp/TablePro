import {
    Action,
    ActionPanel,
    Clipboard,
    Icon,
    List,
    showToast,
    Toast,
} from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useState } from "react";
import { searchHistory } from "./lib/mcp";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";
import { summarizeSQL } from "./lib/sql";

export default function SearchHistoryCommand() {
    const [query, setQuery] = useState("");
    const {
        data: results,
        isLoading,
        error,
    } = useCachedPromise((q: string) => searchHistory(q, 100), [query], {
        keepPreviousData: true,
    });

    if (error) {
        return (
            <List>
                <ScenarioEmptyView scenario={classifyError(error)} />
            </List>
        );
    }

    return (
        <List
            isLoading={isLoading}
            onSearchTextChange={setQuery}
            searchBarPlaceholder="Search query history"
            throttle
        >
            {!isLoading && results !== undefined && results.length === 0 ? (
                <List.EmptyView
                    icon={Icon.MagnifyingGlass}
                    title="No matching history"
                    description={
                        query
                            ? "Try a different search term."
                            : "Run queries in TablePro to build history."
                    }
                />
            ) : null}
            {(results ?? []).map((entry) => (
                <List.Item
                    key={entry.id}
                    title={summarizeSQL(entry.query, 100)}
                    subtitle={entry.connectionName}
                    accessories={[
                        { text: entry.executedAt },
                        ...(entry.rowCount !== undefined
                            ? [{ tag: `${entry.rowCount} rows` }]
                            : []),
                    ]}
                    icon={Icon.Clock}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Copy SQL"
                                icon={Icon.Clipboard}
                                onAction={async () => {
                                    await Clipboard.copy(entry.query);
                                    await showToast({
                                        style: Toast.Style.Success,
                                        title: "SQL copied",
                                    });
                                }}
                            />
                        </ActionPanel>
                    }
                />
            ))}
        </List>
    );
}
