import {
    Action,
    ActionPanel,
    Icon,
    List,
    launchCommand,
    LaunchType,
    openExtensionPreferences,
    open,
} from "@raycast/api";
import { ErrorScenario, describeScenario } from "./errors";

interface Props {
    scenario: ErrorScenario;
}

export function ScenarioEmptyView({ scenario }: Props) {
    const { title, description } = describeScenario(scenario);

    switch (scenario.kind) {
        case "not-installed":
            return (
                <List.EmptyView
                    icon={Icon.Download}
                    title={title}
                    description={description}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open Tablepro Website"
                                icon={Icon.Globe}
                                onAction={() => open("https://tablepro.app")}
                            />
                        </ActionPanel>
                    }
                />
            );
        case "mcp-not-running":
            return (
                <List.EmptyView
                    icon={Icon.Plug}
                    title={title}
                    description={description}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open Tablepro"
                                icon={Icon.AppWindow}
                                onAction={() =>
                                    open("tablepro://integrations/start-mcp")
                                }
                            />
                        </ActionPanel>
                    }
                />
            );
        case "no-token":
            return (
                <List.EmptyView
                    icon={Icon.Key}
                    title={title}
                    description={description}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Pair with Tablepro"
                                icon={Icon.Key}
                                onAction={async () => {
                                    await launchCommand({
                                        name: "pair",
                                        type: LaunchType.UserInitiated,
                                    });
                                }}
                            />
                            <Action
                                title="Open Extension Preferences"
                                icon={Icon.Gear}
                                onAction={openExtensionPreferences}
                            />
                        </ActionPanel>
                    }
                />
            );
        case "token-revoked":
            return (
                <List.EmptyView
                    icon={Icon.XMarkCircle}
                    title={title}
                    description={description}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Pair with Tablepro"
                                icon={Icon.Key}
                                onAction={async () => {
                                    await launchCommand({
                                        name: "pair",
                                        type: LaunchType.UserInitiated,
                                    });
                                }}
                            />
                        </ActionPanel>
                    }
                />
            );
        case "access-denied":
            return (
                <List.EmptyView
                    icon={Icon.Lock}
                    title={title}
                    description={description}
                />
            );
        case "other":
            return (
                <List.EmptyView
                    icon={Icon.Warning}
                    title={title}
                    description={description}
                />
            );
    }
}
