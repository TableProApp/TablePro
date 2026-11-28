using Microsoft.UI.Xaml;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The AI assistant beside the tabs, one pane per session, and the query tabs' AI commands.
public sealed partial class WorkspaceView
{
    private AssistantPane? _assistantPane;
    private DatabaseSession? _assistantSession;

    public bool AssistantVisible => SideHost.Visibility == Visibility.Visible && SideHost.Child is AssistantPane;

    public bool CanShowAssistant => _session is not null;

    // Off with no provider, Blocked under the connection's Never; the Query menu's AI commands follow it.
    public AssistantAvailability AssistantAvailability =>
        new AssistantAccess(() => _workbench.Settings.Assistant, () => _connection.AiPolicy).Availability;

    // The Query menu's AI commands act on the query tab in front.
    public bool CanAskAssistant => ActiveTab is QueryTabView && AssistantTakesStatements;

    // A command engine, as Redis or MongoDB, has no statement to explain. Each query tab's Fix reads it, in front or not.
    private bool AssistantTakesStatements =>
        _session is { } session
        && Grammars.For(session.EngineId) is not (SqlGrammar.Redis or SqlGrammar.Mongo)
        && AssistantAvailability == AssistantAvailability.Ready;

    public void ToggleAssistant()
    {
        if (AssistantVisible)
        {
            HideSidePane();
            ActiveTab?.FocusContent();
            return;
        }

        ShowAssistant()?.FocusComposer();
    }

    // Query > Explain, Review or Optimize with AI, on the statement at the caret of the tab in front.
    public void AskAssistant(AiAction action)
    {
        if (CanAskAssistant && ActiveTab is QueryTabView query)
        {
            query.AskAssistant(action);
        }
    }

    // Explain plan reads the engine's EXPLAIN variants and a statement, not the assistant, so it has no AI gate.
    public bool CanExplainPlan => ActiveTab is QueryTabView query && query.ExplainVariants().Count > 0;

    // Query > Explain plan: the engine's first EXPLAIN variant on the statement at the caret of the tab in front.
    public void ExplainPlan()
    {
        if (ActiveTab is QueryTabView query && query.ExplainVariants() is [var first, ..])
        {
            query.ExplainPlan(first);
        }
    }

    // The connection's policy or the assistant's settings changed: the pane and every tab's Fix read them again.
    public void AssistantChanged()
    {
        _assistantPane?.Refresh();
        foreach (var query in Tabs.TabItems.OfType<Microsoft.UI.Xaml.Controls.TabViewItem>()
                     .Select(item => item.Content)
                     .OfType<QueryTabView>())
        {
            query.OfferFix();
        }

        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnSettingsChanged(object? sender, EventArgs e) => AssistantChanged();

    // Subscribed for the pane's life, not the workspace's time on screen: a reply on its way while Settings shows must
    // still stop when the provider is turned off or moved.
    private void OnPaneSettingsChanged(object? sender, EventArgs e) => _assistantPane?.Refresh();

    private void AttachAssistant(QueryTabView query)
    {
        query.AssistantReady = () => AssistantTakesStatements;
        query.AssistantRequested += OnAssistantRequested;
        query.OfferFix();
    }

    private void DetachAssistant(QueryTabView query)
    {
        query.AssistantRequested -= OnAssistantRequested;
        query.AssistantReady = static () => false;
        query.OfferFix();
    }

    private void OnAssistantRequested(object? sender, AssistantRequest request)
    {
        if (ShowAssistant() is { } pane)
        {
            pane.RunAction(request.Action, request.Statement, request.Error);
        }
    }

    private AssistantPane? ShowAssistant()
    {
        if (_session is not { } session)
        {
            return null;
        }

        var pane = PaneFor(session);
        ShowSidePane(pane);
        pane.Refresh();
        return pane;
    }

    // A new session builds a new pane, so an answer under Ask each time lasts until the connection disconnects.
    private AssistantPane PaneFor(DatabaseSession session)
    {
        if (_assistantPane is { } kept && ReferenceEquals(_assistantSession, session))
        {
            return kept;
        }

        _assistantPane?.Shutdown();
        _workbench.SettingsChanged -= OnPaneSettingsChanged;
        _workbench.SettingsChanged += OnPaneSettingsChanged;
        var pane = new AssistantPane(_workbench, new AssistantHooks(
            session,
            _connection.Name,
            _workbench.EngineName(session.EngineId),
            () => _connection.AiPolicy,
            () => (ActiveTab as QueryTabView)?.Editor?.Text,
            () => (ActiveTab as QueryTabView)?.Database,
            InsertFromAssistant,
            () => Host?.ShowSettings(),
            () => _workbench.McpHost,
            () => _workbench.ActiveProject));
        pane.CloseRequested += (_, _) =>
        {
            HideSidePane();
            ActiveTab?.FocusContent();
        };
        _assistantPane = pane;
        _assistantSession = session;
        return pane;
    }

    // The session ended: what the pane has on its way stops, and a reconnect asks again.
    private void EndAssistant()
    {
        if (AssistantVisible)
        {
            HideSidePane();
        }

        _workbench.SettingsChanged -= OnPaneSettingsChanged;
        _assistantPane?.Shutdown();
        _assistantPane = null;
        _assistantSession = null;
    }

    // Over the selection or at the caret of the query tab in front, as one step Undo takes back; else a new tab.
    private void InsertFromAssistant(string code)
    {
        if (ActiveTab is not QueryTabView { Editor: { } editor } query)
        {
            NewQueryTab(code);
            return;
        }

        var selection = editor.Model.Primary;
        editor.Model.ReplaceRange(selection.Start, selection.End, code);
        editor.EnsureCaretVisible();
        editor.Invalidate();
        query.FocusContent();
    }
}
