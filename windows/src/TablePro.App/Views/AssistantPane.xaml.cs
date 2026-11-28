using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

// What the pane reaches in its workspace. Policy and the editor are read again for each request.
internal sealed record AssistantHooks(
    DatabaseSession Session,
    string ConnectionName,
    string EngineName,
    Func<AiPolicy> Policy,
    Func<string?> EditorText,
    Func<string?> EditorDatabase,
    Action<string> Insert,
    Action OpenSettings,
    // Agent mode opens connections through this and lists the project the app shows; null before the host is set.
    Func<IMcpAppHost?> McpHost,
    Func<Guid?> ActiveProject);

// One conversation at a time about one session's tables, its replies streaming in. The workspace builds a new pane
// for each session, so an answer under Ask each time lasts until the connection disconnects.
public sealed partial class AssistantPane : UserControl
{
    private static readonly TimeSpan PaintEvery = TimeSpan.FromMilliseconds(80);
    private static readonly FontFamily Monospace = new("Cascadia Mono, Consolas, Courier New");

    private readonly Workbench _workbench;
    private readonly AssistantHooks _hooks;
    private readonly AssistantAccess _access;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _painter;
    private AssistantConversation? _conversation;
    private CancellationTokenSource? _work;
    private AiReply? _reply;

    // Where the reply on its way was sent, so a change of provider or address stops it.
    private AiSettings? _replySettings;
    private TurnView? _streaming;
    private TurnView? _lastTurn;
    private bool _busy;

    // Agent mode runs the MCP tools in rounds; the toggle turns it on and a new conversation keeps it.
    private bool _agent;

    // Bumped by each new conversation, so work for an older one that lands late is dropped.
    private int _generation;

    internal AssistantPane(Workbench workbench, AssistantHooks hooks)
    {
        _workbench = workbench;
        _hooks = hooks;
        _access = new AssistantAccess(() => _workbench.Settings.Assistant, hooks.Policy);
        InitializeComponent();
        _painter = DispatcherQueue.CreateTimer();
        _painter.IsRepeating = false;
        _painter.Interval = PaintEvery;
        _painter.Tick += (_, _) => _streaming?.Paint();
        Refresh();
    }

    public event EventHandler? CloseRequested;

    // Show what the assistant can do here now: off, kept from this connection, or the conversation. The workspace
    // calls it as the settings or the connection's policy change.
    public void Refresh()
    {
        var availability = _access.Availability;
        // A reply on its way stops as Stop stops it, so its turn keeps what came, once it may no longer go where it went.
        if (_reply is not null && (_replySettings is null || !_access.MaySendTo(_replySettings)))
        {
            _reply.Cancel();
        }

        OffPanel.Visibility = availability == AssistantAvailability.Off ? Visibility.Visible : Visibility.Collapsed;
        BlockedPanel.Visibility = availability == AssistantAvailability.Blocked ? Visibility.Visible : Visibility.Collapsed;
        ChatPanel.Visibility = availability == AssistantAvailability.Ready ? Visibility.Visible : Visibility.Collapsed;
        ComposerBar.Visibility = ChatPanel.Visibility;
        var settings = _workbench.Settings.Assistant;
        ModelText.Text = settings?.Model ?? string.Empty;
        EmptyText.Text = settings is null
            ? string.Empty
            : Strings.Format("AssistantEmpty", AssistantText.Destination(settings));
        SyncControls();
    }

    // Starts a new conversation on an editor's statement.
    internal void RunAction(AiAction action, string statement, string? error = null)
    {
        NewConversation();
        Ask(new AssistantAsk.Action(action, statement, error));
    }

    // A pane shown for the first time has not loaded yet, and an unloaded box takes no focus.
    public void FocusComposer()
    {
        if (ComposerBar.Visibility != Visibility.Visible)
        {
            return;
        }

        if (Composer.IsLoaded)
        {
            Composer.Focus(FocusState.Programmatic);
            return;
        }

        void OnLoaded(object sender, RoutedEventArgs e)
        {
            Composer.Loaded -= OnLoaded;
            Composer.Focus(FocusState.Programmatic);
        }

        Composer.Loaded += OnLoaded;
    }

    // The session ends: whatever is on its way stops, and work that lands after is dropped.
    public void Shutdown()
    {
        _generation++;
        StopWork();
    }

    private void OnClose(object sender, RoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);

    private void OnOpenSettings(object sender, RoutedEventArgs e) => _hooks.OpenSettings();

    private void OnNewConversation(object sender, RoutedEventArgs e)
    {
        NewConversation();
        FocusComposer();
    }

    // Agent mode starts fresh so its tool cards do not mix with a plain chat; the toggle stays on until turned off.
    private void OnAgentToggled(object sender, RoutedEventArgs e)
    {
        _agent = AgentToggle.IsChecked == true;
        NewConversation();
        FocusComposer();
    }

    private void OnComposerChanged(object sender, TextChangedEventArgs e) => SyncControls();

    // Enter sends, as a chat does; Shift+Enter starts a new line. An input method's Enter comes as ProcessKey.
    private void OnComposerKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }

        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (!shift)
        {
            e.Handled = true;
            SendTyped();
        }
    }

    private void OnSend(object sender, RoutedEventArgs e) => SendTyped();

    private void OnStop(object sender, RoutedEventArgs e) => _reply?.Cancel();

    private void SendTyped()
    {
        var text = Composer.Text.Trim();
        if (text.Length > 0 && !_busy)
        {
            Ask(new AssistantAsk.Typed(text));
        }
    }

    private void SyncControls()
    {
        var replying = _reply is not null;
        SendButton.Visibility = replying ? Visibility.Collapsed : Visibility.Visible;
        StopButton.Visibility = replying ? Visibility.Visible : Visibility.Collapsed;
        SendButton.IsEnabled = !_busy && !string.IsNullOrWhiteSpace(Composer.Text);
        NewButton.IsEnabled = _conversation is not null || _busy;
        var started = Messages.Children.Count > 0;
        EmptyText.Visibility = started ? Visibility.Collapsed : Visibility.Visible;
        Scroller.Visibility = started ? Visibility.Visible : Visibility.Collapsed;
    }

    private void NewConversation()
    {
        StopWork();
        _generation++;
        _conversation = null;
        _lastTurn = null;
        Messages.Children.Clear();
        SyncControls();
    }

    // Drops the request in flight, whatever stage it is at.
    private void StopWork()
    {
        _work?.Cancel();
        _work = null;
        _reply?.Dispose();
        _reply = null;
        _replySettings = null;
        _painter.Stop();
        _streaming = null;
        _busy = false;
    }

    private async void Ask(AssistantAsk asked)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        SyncControls();
        var generation = _generation;
        using var work = new CancellationTokenSource();
        _work = work;
        try
        {
            var allowed = await _access.PermitAsync(settings => ConfirmAsync(settings, work.Token)).ConfigureAwait(true);
            if (generation != _generation)
            {
                return;
            }

            if (!allowed)
            {
                EndWork(generation);
                Refresh();
                return;
            }

            if (asked is AssistantAsk.Typed)
            {
                Composer.Text = string.Empty;
            }

            await BeginTurnAsync(asked, generation, work.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            // A new conversation or the session's end stopped it; the work was let go there.
        }
        finally
        {
            if (ReferenceEquals(_work, work))
            {
                _work = null;
            }
        }
    }

    // Starts the conversation when there is none, shows the question and asks for the reply.
    private async Task BeginTurnAsync(AssistantAsk asked, int generation, CancellationToken cancellationToken)
    {
        IReadOnlyList<string> described = [];
        if (_conversation is null)
        {
            var editor = asked is AssistantAsk.Typed ? _hooks.EditorText() : null;
            var named = asked switch
            {
                AssistantAsk.Typed typed => typed.Text,
                AssistantAsk.Action action => action.Statement,
                _ => string.Empty,
            };
            AiConversationStart start;
            try
            {
                start = await _workbench.Core.Assistant.StartConversationAsync(
                        _hooks.Session,
                        new AiConversationRequest(_hooks.EngineName, named, editor, _hooks.EditorDatabase()),
                        cancellationToken)
                    .ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                if (generation == _generation)
                {
                    var refused = ShowTurn(asked, []);
                    Failed(refused, generation, AssistantText.Error(exception.Error), retry: false);
                    Refresh();
                }

                return;
            }

            if (generation != _generation)
            {
                return;
            }

            _conversation = new AssistantConversation(start.System, start.Described);
            described = start.Described;
        }

        var message = asked switch
        {
            AssistantAsk.Action action => AiAssistant.ActionMessage(action.Kind, action.Statement, action.Error),
            AssistantAsk.Typed typed => typed.Text,
            _ => string.Empty,
        };
        _conversation.Ask(asked, message);
        var turn = ShowTurn(asked, described);
        await ReplyAsync(turn, generation, cancellationToken).ConfigureAwait(true);
    }

    private async Task ReplyAsync(TurnView turn, int generation, CancellationToken cancellationToken)
    {
        turn.Waiting();
        // Settings or the policy may have changed while the request was made, so it is asked again where it must be.
        var settings = _workbench.Settings.Assistant;
        if (settings is null || !_access.MaySendTo(settings))
        {
            var allowed = await _access.PermitAsync(asked => ConfirmAsync(asked, cancellationToken)).ConfigureAwait(true);
            settings = _workbench.Settings.Assistant;
            if (generation != _generation)
            {
                return;
            }

            if (!allowed || settings is null || !_access.MaySendTo(settings))
            {
                Failed(turn, generation, Strings.Get("AssistantNotAllowedNow"), retry: false);
                Refresh();
                return;
            }
        }

        if (_conversation is not { } conversation)
        {
            EndWork(generation);
            return;
        }

        // A stop that came while this was asked starts no request.
        cancellationToken.ThrowIfCancellationRequested();
        if (StartReply(settings, conversation) is not { } reply)
        {
            Failed(turn, generation, Strings.Get("AssistantAgentUnavailable"), retry: false);
            return;
        }

        _reply = reply;
        _replySettings = settings;
        _streaming = turn;
        SyncControls();
        await foreach (var replyEvent in reply.ReadEventsAsync(cancellationToken).ConfigureAwait(true))
        {
            switch (replyEvent)
            {
                case AiReplyEvent.Text text:
                    turn.Append(text.Part);
                    if (!_painter.IsRunning)
                    {
                        _painter.Start();
                    }

                    break;
                case AiReplyEvent.ToolCall call:
                    turn.ToolCall(call.Id, call.Name, call.Input);
                    break;
                case AiReplyEvent.ToolStarted started:
                    turn.ToolStarted(started.Id);
                    break;
                case AiReplyEvent.ToolFinished done:
                    turn.ToolFinished(done.Id, done.Output, done.IsError);
                    break;
                case AiReplyEvent.Finished finished:
                    Finished(turn, generation, finished);
                    break;
                case AiReplyEvent.Failed failed:
                    Failed(turn, generation, AssistantText.Error(failed.Error), retry: true);
                    break;
                default:
                    Stopped(turn, generation);
                    break;
            }
        }
    }

    // A plain reply, or the agent loop when the toggle is on. Null when agent mode has no host to open connections.
    private AiReply? StartReply(AiSettings settings, AssistantConversation conversation)
    {
        if (!_agent)
        {
            return _workbench.Core.Assistant.Reply(_hooks.Session, settings, conversation.Request());
        }

        if (_hooks.McpHost() is not { } host)
        {
            return null;
        }

        var approver = new AssistantApprover(DispatcherQueue, ApproveWriteAsync);
        return _workbench.Core.Assistant.ReplyAgentic(
            _hooks.Session,
            settings,
            conversation.Request(),
            _hooks.ActiveProject(),
            host,
            approver);
    }

    // The agent asks before a write runs. Deny is the default; the question names the connection and the statement.
    private async Task<bool> ApproveWriteAsync(AiWriteRequest request, CancellationToken withdrawn)
    {
        if (!IsLoaded)
        {
            await LoadedAsync(withdrawn).ConfigureAwait(true);
        }

        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(new TextBlock
        {
            Text = request.Destructive
                ? Strings.Format("AssistantWriteDestructive", _hooks.ConnectionName)
                : Strings.Format("AssistantWriteMessage", _hooks.ConnectionName),
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(CodeBlock(request.Sql, actions: false));
        AutomationProperties.SetAutomationId(body, "AssistantWriteRequest");
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("AssistantWriteTitle"),
            Content = body,
            PrimaryButtonText = Strings.Get("AssistantWriteAllow"),
            CloseButtonText = Strings.Get("AssistantWriteDeny"),
            DefaultButton = ContentDialogButton.Close,
        };
        using var registration = withdrawn.Register(dialog.Hide);
        try
        {
            var answer = await WindowDialogs.ShowAsync(dialog, this, withdrawn).ConfigureAwait(true);
            return answer == ContentDialogResult.Primary;
        }
        catch (OperationCanceledException)
        {
            // The reply ended while the question was open.
            return false;
        }
    }

    private void Finished(TurnView turn, int generation, AiReplyEvent.Finished end)
    {
        if (!EndReply(turn, generation))
        {
            return;
        }

        _conversation?.Answer(turn.Text);
        var note = end.Stop switch
        {
            AiStop.LengthLimit => Strings.Get("AssistantLengthLimit"),
            AiStop.Refused => Strings.Get("AssistantRefused"),
            _ => null,
        };
        var total = (end.InputTokens ?? 0) + (end.OutputTokens ?? 0);
        var tokens = end.InputTokens is null && end.OutputTokens is null
            ? null
            : Strings.Plural("AssistantTokens", total, total);
        turn.Ended(Strings.Sentences(note, tokens));
        Announce(Strings.Get("AssistantAnswered"));
    }

    private void Stopped(TurnView turn, int generation)
    {
        if (!EndReply(turn, generation))
        {
            return;
        }

        if (turn.Text.Length > 0)
        {
            _conversation?.Answer(turn.Text);
        }

        turn.Ended(Strings.Get("AssistantStopped"));
    }

    private void Failed(TurnView turn, int generation, string message, bool retry)
    {
        if (!EndReply(turn, generation))
        {
            return;
        }

        turn.Failed(message, retry ? () => Retry(turn) : null);
        Announce(message);
    }

    // Whether the reply that ended belongs to the conversation shown; the pane is free for the next question either way.
    private bool EndReply(TurnView turn, int generation)
    {
        if (generation != _generation)
        {
            return false;
        }

        _painter.Stop();
        turn.Paint();
        EndWork(generation);
        return true;
    }

    private void EndWork(int generation)
    {
        if (generation != _generation)
        {
            return;
        }

        _reply?.Dispose();
        _reply = null;
        _replySettings = null;
        _streaming = null;
        _busy = false;
        SyncControls();
    }

    // Asks again for the last turn's reply, which failed, after the same check a new question goes through.
    private async void Retry(TurnView turn)
    {
        if (_busy || !ReferenceEquals(turn, _lastTurn) || _conversation is null)
        {
            return;
        }

        _busy = true;
        turn.Clear();
        SyncControls();
        var generation = _generation;
        using var work = new CancellationTokenSource();
        _work = work;
        try
        {
            await ReplyAsync(turn, generation, work.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            // A new conversation or the session's end stopped it.
        }
        finally
        {
            if (ReferenceEquals(_work, work))
            {
                _work = null;
            }
        }
    }

    // Cancel is the answer Enter gives, and the question names the connection and where its data goes.
    private async Task<bool> ConfirmAsync(AiSettings settings, CancellationToken cancellationToken)
    {
        // An editor action shows the pane and asks at once, before the pane has joined the window.
        if (!IsLoaded)
        {
            await LoadedAsync(cancellationToken).ConfigureAwait(true);
        }

        var text = new TextBlock
        {
            Text = Strings.Format("AssistantConsentMessage", _hooks.ConnectionName, AssistantText.Destination(settings)),
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetAutomationId(text, "AssistantConsentText");
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("AssistantConsentTitle"),
            Content = text,
            PrimaryButtonText = Strings.Get("AssistantConsentAllow"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        // A request stopped while it asks takes the question down with it.
        using var registration = cancellationToken.Register(dialog.Hide);
        var answer = await WindowDialogs.ShowAsync(dialog, this, cancellationToken).ConfigureAwait(true);
        cancellationToken.ThrowIfCancellationRequested();
        return answer == ContentDialogResult.Primary;
    }

    private Task LoadedAsync(CancellationToken cancellationToken)
    {
        var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnLoaded(object sender, RoutedEventArgs args)
        {
            Loaded -= OnLoaded;
            loaded.TrySetResult();
        }

        Loaded += OnLoaded;
        return loaded.Task.WaitAsync(cancellationToken);
    }

    private TurnView ShowTurn(AssistantAsk asked, IReadOnlyList<string> described)
    {
        // Only the last turn's reply can be asked for again.
        _lastTurn?.DropRetry();
        var turn = new TurnView(this, asked, described);
        Messages.Children.Add(turn.Root);
        _lastTurn = turn;
        SyncControls();
        Scroller.UpdateLayout();
        Scroller.ChangeView(null, Scroller.ScrollableHeight, null, disableAnimation: true);
        return turn;
    }

    // Narrator says it whether or not the pane has focus, as a reply ends while the user reads elsewhere.
    private void Announce(string message) =>
        (FrameworkElementAutomationPeer.FromElement(this) ?? FrameworkElementAutomationPeer.CreatePeerForElement(this))
            ?.RaiseNotificationEvent(
                AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.ImportantMostRecent,
                message,
                "TableProAssistantReply");

    private void Insert(string code) => _hooks.Insert(code);

    private static void Copy(string code)
    {
        var package = new DataPackage();
        package.SetText(code);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (COMException)
        {
            // Another program holds the clipboard; the code stays selectable in the block.
        }
    }

    // One question and its reply on screen.
    private sealed class TurnView
    {
        private readonly AssistantPane _pane;
        private readonly StackPanel _tools = new() { Spacing = 8 };
        private readonly Dictionary<string, ToolCardView> _cards = [];
        private readonly StackPanel _reply = new() { Spacing = 8 };
        private readonly StackPanel _footer = new() { Spacing = 8 };
        private readonly StringBuilder _text = new();
        private Button? _retry;
        private int _painted;

        public TurnView(AssistantPane pane, AssistantAsk asked, IReadOnlyList<string> described)
        {
            _pane = pane;
            Root = new StackPanel { Spacing = 8 };
            Root.Children.Add(Question(asked));
            if (described.Count > 0)
            {
                Root.Children.Add(pane.Caption(Strings.Format("AssistantSentStructure", Strings.List(described))));
            }

            AutomationProperties.SetAutomationId(_tools, "AssistantToolCards");
            Root.Children.Add(_tools);
            AutomationProperties.SetAutomationId(_reply, "AssistantReply");
            Root.Children.Add(_reply);
            Root.Children.Add(_footer);
        }

        // One agent tool call: its card shows the arguments, a running state, then its result.
        public void ToolCall(string id, string name, string input)
        {
            if (_cards.ContainsKey(id))
            {
                return;
            }

            var card = new ToolCardView(_pane, name, input);
            _cards[id] = card;
            _tools.Children.Add(card.Root);
            _pane.FollowEnd();
        }

        public void ToolStarted(string id)
        {
            if (_cards.TryGetValue(id, out var card))
            {
                card.Started();
            }
        }

        public void ToolFinished(string id, string output, bool isError)
        {
            if (_cards.TryGetValue(id, out var card))
            {
                card.Finished(output, isError);
            }

            _pane.FollowEnd();
        }

        public StackPanel Root { get; }

        public string Text => _text.ToString();

        public void Append(string part) => _text.Append(part);

        public void Waiting()
        {
            _footer.Children.Clear();
            var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
            AutomationProperties.SetName(ring, Strings.Get("AssistantWaiting"));
            _footer.Children.Add(ring);
        }

        public void Clear()
        {
            _text.Clear();
            _painted = 0;
            _retry = null;
            _cards.Clear();
            _tools.Children.Clear();
            _reply.Children.Clear();
            _footer.Children.Clear();
        }

        // Each paint reads the whole reply again, so the pane paints at most every PaintEvery while it streams.
        public void Paint()
        {
            if (_text.Length == _painted)
            {
                return;
            }

            _painted = _text.Length;
            if (_footer.Children.FirstOrDefault() is ProgressRing)
            {
                _footer.Children.Clear();
            }

            _reply.Children.Clear();
            foreach (var block in ReplyMarkdown.Read(_text.ToString()))
            {
                _reply.Children.Add(block switch
                {
                    ReplyBlock.Code code => _pane.CodeBlock(code.Text, actions: true),
                    ReplyBlock.Paragraph paragraph => Prose(paragraph),
                    _ => new TextBlock(),
                });
            }

            _pane.FollowEnd();
        }

        public void Ended(string note)
        {
            _footer.Children.Clear();
            if (note.Length > 0)
            {
                _footer.Children.Add(_pane.Caption(note));
            }
        }

        public void Failed(string message, Action? retry)
        {
            _footer.Children.Clear();
            var text = new TextBlock { Text = message, Style = _pane.Named("AssistantErrorStyle") };
            AutomationProperties.SetAutomationId(text, "AssistantError");
            _footer.Children.Add(text);
            if (retry is not null)
            {
                var button = new Button { Content = Strings.Get("AssistantRetry") };
                AutomationProperties.SetAutomationId(button, "AssistantRetryButton");
                button.Click += (_, _) => retry();
                _footer.Children.Add(button);
                _retry = button;
            }
        }

        public void DropRetry()
        {
            if (_retry is { } retry)
            {
                _footer.Children.Remove(retry);
                _retry = null;
            }
        }

        private Border Question(AssistantAsk asked)
        {
            var card = new StackPanel { Spacing = 6 };
            switch (asked)
            {
                case AssistantAsk.Typed typed:
                    card.Children.Add(new TextBlock { Text = typed.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                    break;
                case AssistantAsk.Action action:
                    card.Children.Add(new TextBlock
                    {
                        Text = AssistantText.Action(action.Kind),
                        Style = _pane.Named("AssistantTitleStyle"),
                    });
                    card.Children.Add(_pane.CodeBlock(action.Statement, actions: false));
                    if (action.Error is { Length: > 0 } error)
                    {
                        card.Children.Add(_pane.Caption(error));
                    }

                    break;
            }

            return new Border { Child = card, Style = _pane.Named("AssistantQuestionStyle") };
        }

        private static RichTextBlock Prose(ReplyBlock.Paragraph paragraph)
        {
            var block = new Paragraph();
            foreach (var span in paragraph.Spans)
            {
                var lines = span.Text.Split('\n');
                for (var index = 0; index < lines.Length; index++)
                {
                    if (index > 0)
                    {
                        block.Inlines.Add(new LineBreak());
                    }

                    if (lines[index].Length == 0)
                    {
                        continue;
                    }

                    Inline run = span.Style switch
                    {
                        ReplySpanStyle.Bold => new Bold { Inlines = { new Run { Text = lines[index] } } },
                        ReplySpanStyle.Code => new Run { Text = lines[index], FontFamily = Monospace },
                        _ => new Run { Text = lines[index] },
                    };
                    block.Inlines.Add(run);
                }
            }

            var text = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
            if (paragraph.IsHeading)
            {
                text.FontWeight = FontWeights.SemiBold;
            }

            text.Blocks.Add(block);
            return text;
        }
    }

    // One tool call's card: the tool and its arguments, a running state, then the result or its error.
    private sealed class ToolCardView
    {
        private readonly AssistantPane _pane;
        private readonly StackPanel _status = new() { Spacing = 6 };

        public ToolCardView(AssistantPane pane, string name, string input)
        {
            _pane = pane;
            var panel = new StackPanel { Spacing = 6 };
            panel.Children.Add(new TextBlock { Text = name, FontFamily = Monospace, Style = pane.Named("AssistantTitleStyle") });
            if (input is { Length: > 0 } && input != "{}")
            {
                panel.Children.Add(Output(input));
            }

            panel.Children.Add(_status);
            Running();
            Root = new Border { Child = panel, Style = pane.Named("AssistantToolCardStyle") };
            AutomationProperties.SetAutomationId(Root, "AssistantToolCard");
        }

        public Border Root { get; }

        public void Started() => Running();

        public void Finished(string output, bool isError)
        {
            _status.Children.Clear();
            if (isError)
            {
                var text = new TextBlock { Text = output, Style = _pane.Named("AssistantErrorStyle") };
                AutomationProperties.SetAutomationId(text, "AssistantToolError");
                _status.Children.Add(text);
                return;
            }

            _status.Children.Add(Output(output));
        }

        private void Running()
        {
            _status.Children.Clear();
            var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
            AutomationProperties.SetName(ring, Strings.Get("AssistantToolRunning"));
            _status.Children.Add(ring);
        }

        // A tool's JSON, wrapped and scrollable so a long answer does not grow the pane without bound.
        private static ScrollViewer Output(string text) => new()
        {
            MaxHeight = 160,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new TextBlock
            {
                Text = text,
                FontFamily = Monospace,
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            },
        };
    }

    private void FollowEnd()
    {
        // Follows the reply as it grows while the user is at the end, and leaves them where they scrolled to.
        if (Scroller.VerticalOffset >= Scroller.ScrollableHeight - 24)
        {
            Scroller.UpdateLayout();
            Scroller.ChangeView(null, Scroller.ScrollableHeight, null, disableAnimation: true);
        }
    }

    // Code from a reply has Copy and Insert in editor; the question's statement is only shown.
    private Border CodeBlock(string code, bool actions)
    {
        var text = new TextBlock
        {
            Text = code,
            FontFamily = Monospace,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
        };
        AutomationProperties.SetAutomationId(text, actions ? "AssistantCode" : "AssistantStatement");
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new ScrollViewer
        {
            Content = text,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollMode = ScrollMode.Disabled,
        });
        if (actions)
        {
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            var copy = new Button { Content = Strings.Get("AssistantCopyCode") };
            AutomationProperties.SetAutomationId(copy, "AssistantCopyCode");
            copy.Click += (_, _) => Copy(code);
            var insert = new Button { Content = Strings.Get("AssistantInsertCode") };
            AutomationProperties.SetAutomationId(insert, "AssistantInsertCode");
            insert.Click += (_, _) => Insert(code);
            buttons.Children.Add(copy);
            buttons.Children.Add(insert);
            panel.Children.Add(buttons);
        }

        return new Border { Child = panel, Style = Named("AssistantCodeStyle") };
    }

    private Style Named(string key) => (Style)Resources[key];

    private TextBlock Caption(string text) => new() { Text = text, Style = Named("AssistantCaptionStyle") };
}
