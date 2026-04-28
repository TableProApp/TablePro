import {
    Action,
    ActionPanel,
    Detail,
    Form,
    Icon,
    LaunchProps,
    LocalStorage,
    Toast,
    showToast,
    showHUD,
    useNavigation,
    open,
    openExtensionPreferences,
    popToRoot,
    updateCommandMetadata,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { hostname } from "os";
import { Connection, TableProNotInstalledError } from "./lib/types";
import { databaseTypeLabel, loadConnections } from "./lib/connections";
import { tableProInstalled } from "./lib/paths";
import { pairDeeplink } from "./lib/deeplink";
import { exchangePairingCode } from "./lib/mcp";
import { generatePKCE, PAIR_CALLBACK_URL, STORAGE_KEYS } from "./lib/pairing";
import { classifyError } from "./lib/errors";

interface LaunchContext {
    code?: string;
}

const SCOPE_OPTIONS = [
    { value: "read", label: "Read-only" },
    { value: "read-write", label: "Read & write" },
    { value: "full", label: "Full access" },
];

export default function PairCommand(
    props: LaunchProps<{ launchContext: LaunchContext }>,
) {
    const incomingCode = props.launchContext?.code;
    if (incomingCode) {
        return <ExchangeView code={incomingCode} />;
    }
    return <PairForm />;
}

function PairForm() {
    const [connections, setConnections] = useState<Connection[] | null>(null);
    const [error, setError] = useState<unknown>(null);
    const [selectedConnections, setSelectedConnections] = useState<string[]>(
        [],
    );
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
            <Detail
                markdown={renderErrorMarkdown(error)}
                actions={
                    <ActionPanel>
                        <Action
                            title="Open Extension Preferences"
                            icon={Icon.Gear}
                            onAction={openExtensionPreferences}
                        />
                    </ActionPanel>
                }
            />
        );
    }

    return (
        <Form
            isLoading={connections === null}
            navigationTitle="Pair with TablePro"
            actions={
                <ActionPanel>
                    <Action.SubmitForm
                        title="Continue in TablePro"
                        icon={Icon.AppWindow}
                        onSubmit={async (values: {
                            client: string;
                            scope: string;
                            connections: string[];
                        }) => {
                            try {
                                const { verifier, challenge } = generatePKCE();
                                await LocalStorage.setItem(
                                    STORAGE_KEYS.pendingVerifier,
                                    verifier,
                                );
                                await LocalStorage.setItem(
                                    STORAGE_KEYS.pendingClient,
                                    values.client,
                                );
                                await pairDeeplink({
                                    client: values.client,
                                    challenge,
                                    redirect: PAIR_CALLBACK_URL,
                                    scopes: scopeToList(values.scope),
                                    connectionIds:
                                        values.connections.length > 0
                                            ? values.connections
                                            : undefined,
                                });
                                push(<WaitingView />);
                            } catch (err) {
                                await showToast({
                                    style: Toast.Style.Failure,
                                    title: "Failed to start pairing",
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
        >
            <Form.TextField
                id="client"
                title="Client Name"
                placeholder="Raycast on this Mac"
                defaultValue={`Raycast on ${hostname()}`}
            />
            <Form.Dropdown id="scope" title="Permissions" defaultValue="read">
                {SCOPE_OPTIONS.map((option) => (
                    <Form.Dropdown.Item
                        key={option.value}
                        value={option.value}
                        title={option.label}
                    />
                ))}
            </Form.Dropdown>
            <Form.TagPicker
                id="connections"
                title="Allowed Connections"
                info="Leave empty to allow all current and future connections."
                value={selectedConnections}
                onChange={setSelectedConnections}
            >
                {(connections ?? []).map((connection) => (
                    <Form.TagPicker.Item
                        key={connection.id}
                        value={connection.id}
                        title={`${connection.name} (${databaseTypeLabel(connection.type)})`}
                    />
                ))}
            </Form.TagPicker>
            <Form.Description text="TablePro shows an approval sheet next. Approve there, then come back here. The token is stored in your Raycast preferences." />
        </Form>
    );
}

function WaitingView() {
    const [error, setError] = useState<unknown>(null);
    const [completed, setCompleted] = useState(false);
    const { pop } = useNavigation();

    useEffect(() => {
        let cancelled = false;
        const handle = setInterval(async () => {
            try {
                const code = await LocalStorage.getItem<string>(
                    STORAGE_KEYS.callbackCode,
                );
                if (!code) return;
                await LocalStorage.removeItem(STORAGE_KEYS.callbackCode);
                clearInterval(handle);
                const verifier = await LocalStorage.getItem<string>(
                    STORAGE_KEYS.pendingVerifier,
                );
                if (!verifier) {
                    throw new Error(
                        "Pairing verifier missing. Restart the pairing flow.",
                    );
                }
                const exchange = await exchangePairingCode(code, verifier);
                await persistToken(exchange.token);
                await LocalStorage.removeItem(STORAGE_KEYS.pendingVerifier);
                await LocalStorage.removeItem(STORAGE_KEYS.pendingClient);
                if (cancelled) return;
                setCompleted(true);
                await showHUD("Paired with TablePro");
                await popToRoot({ clearSearchBar: true });
            } catch (err) {
                if (cancelled) return;
                setError(err);
                clearInterval(handle);
            }
        }, 1000);
        return () => {
            cancelled = true;
            clearInterval(handle);
        };
    }, []);

    if (error) {
        return (
            <Detail
                markdown={renderErrorMarkdown(error)}
                actions={
                    <ActionPanel>
                        <Action
                            title="Try Again"
                            icon={Icon.RotateClockwise}
                            onAction={pop}
                        />
                    </ActionPanel>
                }
            />
        );
    }

    const message = completed
        ? "Paired. You can close this window."
        : "Approve the pairing in TablePro. Come back here once you have approved it.";

    return (
        <Detail
            markdown={`# Waiting for approval\n\n${message}`}
            isLoading={!completed}
        />
    );
}

function ExchangeView({ code }: { code: string }) {
    const [error, setError] = useState<unknown>(null);
    const [done, setDone] = useState(false);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            try {
                await LocalStorage.setItem(STORAGE_KEYS.callbackCode, code);
                if (!cancelled) setDone(true);
            } catch (err) {
                if (!cancelled) setError(err);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [code]);

    if (error) {
        return <Detail markdown={renderErrorMarkdown(error)} />;
    }

    return (
        <Detail
            markdown={
                done
                    ? "# Pairing code received\n\nReturn to the open Pair with TablePro window to finish."
                    : "# Receiving pairing code…"
            }
        />
    );
}

function scopeToList(scope: string): string[] {
    switch (scope) {
        case "read":
            return ["connections.read", "schema.read", "query.read"];
        case "read-write":
            return [
                "connections.read",
                "schema.read",
                "query.read",
                "query.write",
            ];
        case "full":
            return [
                "connections.read",
                "schema.read",
                "query.read",
                "query.write",
                "admin",
            ];
        default:
            return ["connections.read", "schema.read", "query.read"];
    }
}

async function persistToken(token: string): Promise<void> {
    await LocalStorage.setItem("apiToken", token);
    try {
        await updateCommandMetadata({ subtitle: "Paired" });
    } catch {
        // updateCommandMetadata is best-effort; ignore failures
    }
    await showToast({
        style: Toast.Style.Success,
        title: "Token issued",
        message:
            "Open extension preferences to paste it into the API Token field.",
        primaryAction: {
            title: "Open Preferences",
            onAction: () => {
                openExtensionPreferences();
            },
        },
    });
    await open(
        `raycast://extensions/ngoquocdat/tablepro?token=${encodeURIComponent(token)}`,
    ).catch(() => undefined);
}

function renderErrorMarkdown(err: unknown): string {
    const scenario = classifyError(err);
    switch (scenario.kind) {
        case "not-installed":
            return "# TablePro is not installed\n\nInstall TablePro from [tablepro.app](https://tablepro.app), then run this command again.";
        case "mcp-not-running":
            return "# TablePro is not running\n\nOpen TablePro and try again. The MCP server starts on demand.";
        case "no-token":
            return "# No token yet\n\nFinish the pairing flow to issue one.";
        case "token-revoked":
            return "# Token was revoked\n\nRun this command to issue a new one.";
        case "access-denied":
            return `# Access denied\n\n${scenario.message}`;
        case "other":
            return `# Pairing failed\n\n${scenario.message}`;
    }
}
