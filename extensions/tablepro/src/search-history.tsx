import {
    Action,
    ActionPanel,
    Clipboard,
    Icon,
    List,
    showToast,
    Toast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { QueryHistoryEntry } from "./lib/types";
import { searchHistory } from "./lib/mcp";
import { ScenarioEmptyView } from "./lib/empty-state";
import { classifyError } from "./lib/errors";
import { summarizeSQL } from "./lib/sql";

export default function SearchHistoryCommand() {
    const [query, setQuery] = useState("");
    const [results, setResults] = useState<QueryHistoryEntry[] | null>(null);
    const [error, setError] = useState<unknown>(null);
    const [isLoading, setIsLoading] = useState(false);

    useEffect(() => {
        let cancelled = false;
        setIsLoading(true);
        const handle = setTimeout(async () => {
            try {
                const data = await searchHistory(query, 100);
                if (!cancelled) {
                    setResults(data);
                    setError(null);
                }
            } catch (err) {
                if (!cancelled) setError(err);
            } finally {
                if (!cancelled) setIsLoading(false);
            }
        }, 200);
        return () => {
            cancelled = true;
            clearTimeout(handle);
        };
    }, [query]);

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
            {results !== null && results.length === 0 ? (
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
