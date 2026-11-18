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
        _workbench.Settings.Assistant is null ? AssistantAvailability.Off
        : _connection.AiPolicy == AiPolicy.Never ? AssistantAvailability.Blocked
        : AssistantAvailability.Ready;

    // A command engine, as Redis or MongoDB, has no statement to explain.
    public bool CanAskAssistant =>
        _session is { } session
        && ActiveTab is QueryTabView
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

    private void AttachAssistant(QueryTabView query)
    {
        query.AssistantReady = () => CanAskAssistant;
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
        var pane = new AssistantPane(_workbench, new AssistantHooks(
            session,
            _connection.Name,
            _workbench.EngineName(session.EngineId),
            () => _connection.AiPolicy,
            () => (ActiveTab as QueryTabView)?.Editor?.Text,
            () => (ActiveTab as QueryTabView)?.Database,
            InsertFromAssistant,
            () => Host?.ShowSettings()));
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
