using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.Ai.Assistant;
using TablePro.Ai.Conversations;
using TablePro.Ai.Prompts;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Schema;
using Windows.System;
using ColumnDefinition = Microsoft.UI.Xaml.Controls.ColumnDefinition;

namespace TablePro.App.Views;

/// <summary>
/// The AI assistant beside the tabs: a conversation that knows the editor's SQL and the structure of the tables it
/// names, with Explain, Optimize, Review and Generate actions. Code in a reply carries Insert and Copy buttons.
/// </summary>
internal sealed partial class AssistantPane : UserControl
{
    private readonly WorkspaceViewModel _workspace;
    private readonly Func<string> _currentSql;
    private readonly Action<string> _insert;
    private readonly AiAssistantService? _service;
    private readonly AiConversation _conversation;
    private readonly StackPanel _messages = new() { Spacing = 12 };
    private readonly ScrollViewer _scroller;
    private readonly TextBox _input = new() { PlaceholderText = Strings.Get("Panes/AssistantInputPlaceholder"),AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 160 };
    private readonly Button _send;
    private CancellationTokenSource? _reply;

    public AssistantPane(AppHost host, WorkspaceViewModel workspace, Func<string> currentSql, Action<string> insert)
    {
        _workspace = workspace;
        _currentSql = currentSql;
        _insert = insert;
        _conversation = new AiConversation(workspace.Profile.Id);
        (_service, var problem) = host.CreateAssistant(workspace.Context.Dialogs);

        _scroller = new ScrollViewer { Content = _messages, Padding = new Thickness(12, 0, 12, 12) };
        _send = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = (Style)Application.Current.Resources["AccentButtonStyle"], VerticalAlignment = VerticalAlignment.Bottom };
        ToolTipService.SetToolTip(_send, Strings.Get("Panes/AssistantSend"));
        AutomationProperties.SetName(_send, Strings.Get("Panes/AssistantSend"));
        _send.Click += async (_, _) => await SendAsync(_input.Text);
        _input.KeyDown += async (_, e) =>
        {
            var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (e.Key == VirtualKey.Enter && ctrl)
            {
                e.Handled = true;
                await SendAsync(_input.Text);
            }
        };

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(12, 0, 12, 8) };
        actions.Children.Add(Action(ActionLabel(AiQueryAction.Explain),"", () => RunActionAsync(AiQueryAction.Explain)));
        actions.Children.Add(Action(ActionLabel(AiQueryAction.Optimize),"", () => RunActionAsync(AiQueryAction.Optimize)));
        actions.Children.Add(Action(ActionLabel(AiQueryAction.Review),"", () => RunActionAsync(AiQueryAction.Review)));
        actions.Children.Add(Action(Strings.Get("Panes/AssistantNewConversation"),"", () =>
        {
            _reply?.Cancel();
            _conversation.Clear();
            _messages.Children.Clear();
            return Task.CompletedTask;
        }));

        var inputRow = new Grid { ColumnSpacing = 8, Padding = new Thickness(12, 0, 12, 12) };
        inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        inputRow.Children.Add(_input);
        Grid.SetColumn(_send, 1);
        inputRow.Children.Add(_send);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(actions);
        Grid.SetRow(_scroller, 1);
        root.Children.Add(_scroller);
        Grid.SetRow(inputRow, 2);
        root.Children.Add(inputRow);
        Content = root;

        if (_service is null)
        {
            _messages.Children.Add(new InfoBar { Severity = InfoBarSeverity.Informational, IsOpen = true, IsClosable = false, Title = Strings.Get("Panes/AssistantSetUpTitle"), Message = problem });
            _input.IsEnabled = false;
            _send.IsEnabled = false;
        }
        else
        {
            _messages.Children.Add(Bubble(Strings.Format("Panes/AssistantUsing", _service.Provider.DisplayName, _service.Model), isUser: false, muted: true));
        }
    }

    private static string ActionLabel(AiQueryAction action) => action switch
    {
        AiQueryAction.Explain => Strings.Get("Panes/AssistantExplain"),
        AiQueryAction.Optimize => Strings.Get("Panes/AssistantOptimize"),
        AiQueryAction.Review => Strings.Get("Panes/AssistantReview"),
        _ => action.ToString(),
    };

    private static Button Action(string text, string glyph, Func<Task> run)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12 });
        content.Children.Add(new TextBlock { Text = text, FontSize = 12 });
        var button = new Button { Content = content, Padding = new Thickness(8, 4, 8, 4) };
        button.Click += async (_, _) => await run();
        return button;
    }

    private async Task SendAsync(string text)
    {
        if (_service is null || string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        _input.Text = string.Empty;
        _messages.Children.Add(Bubble(text, isUser: true));
        var context = await BuildContextAsync(text);
        await StreamAsync(token => _service.SendAsync(_conversation, text, context, token));
    }

    private async Task RunActionAsync(AiQueryAction action)
    {
        var sql = _currentSql();
        if (_service is null || string.IsNullOrWhiteSpace(sql))
        {
            return;
        }

        _messages.Children.Add(Bubble(Strings.Format("Panes/AssistantActionBubble", ActionLabel(action), sql), isUser: true));
        var context = await BuildContextAsync(sql);
        await StreamAsync(token => _service.RunQueryActionAsync(_conversation, action, sql, null, context, token));
    }

    /// <summary>Asks for a corrected statement, sending the server's error alongside the SQL it refused.</summary>
    public async Task FixAsync(string sql, string error)
    {
        if (_service is null)
        {
            return;
        }

        _messages.Children.Add(Bubble(Strings.Format("Panes/AssistantFixBubble", sql, error), isUser: true));
        var context = await BuildContextAsync(sql);
        await StreamAsync(token => _service.RunQueryActionAsync(_conversation, AiQueryAction.FixError, sql, error, context, token));
    }

    private async Task StreamAsync(Func<CancellationToken, IAsyncEnumerable<string>> start)
    {
        _reply?.Cancel();
        _reply = new CancellationTokenSource();
        var token = _reply.Token;
        var text = new StringBuilder();
        var block = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Text = "…" };
        var bubble = Bubble(block, isUser: false);
        _messages.Children.Add(bubble);
        try
        {
            await foreach (var delta in start(token))
            {
                text.Append(delta);
                block.Text = text.ToString();
                _scroller.ChangeView(null, _scroller.ScrollableHeight, null, disableAnimation: true);
            }
        }
        catch (AiAccessDeniedException ex)
        {
            text.Clear().Append(ex.Message);
        }
        catch (OperationCanceledException)
        {
            text.Append("\n\n").Append(Strings.Get("Panes/AssistantStopped"));
        }
        catch (Exception ex) when (ex is HttpRequestException or Ai.AiProviderException or InvalidOperationException)
        {
            text.Append("\n\n").Append(ex.Message);
        }

        _messages.Children.Remove(bubble);
        _messages.Children.Add(RenderReply(text.ToString()));
        _scroller.ChangeView(null, _scroller.ScrollableHeight, null, disableAnimation: true);
    }

    /// <summary>The structure of tables named in the text, so the model writes against the real columns.</summary>
    private async Task<AiRequestContext> BuildContextAsync(string text)
    {
        var session = _workspace.Session;
        var named = session.Objects
            .Where(o => o.HasRows && text.Contains(o.Name.Name, StringComparison.OrdinalIgnoreCase))
            .Take(20)
            .ToList();
        if (named.Count == 0)
        {
            named = session.Objects.Where(o => o.Kind == ObjectKind.Table).Take(12).ToList();
        }

        var structures = new List<TableStructure>(named.Count);
        foreach (var obj in named)
        {
            try
            {
                structures.Add(await session.GetStructureAsync(obj.Name, CancellationToken.None));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A table the login cannot describe is left out of the context.
            }
        }

        return new AiRequestContext
        {
            Profile = session.Profile,
            Schema = SchemaContext.For(session.Database, structures),
            EditorText = _currentSql(),
        };
    }

    private Border RenderReply(string markdown)
    {
        var panel = new StackPanel { Spacing = 8 };
        var position = 0;
        foreach (var block in MarkdownFence.ExtractCodeBlocks(markdown))
        {
            var start = markdown.IndexOf(block.Code, position, StringComparison.Ordinal);
            if (start < 0)
            {
                continue;
            }

            var fenceStart = markdown.LastIndexOf("```", start, StringComparison.Ordinal);
            if (fenceStart > position)
            {
                panel.Children.Add(Prose(markdown[position..fenceStart]));
            }

            panel.Children.Add(CodeCard(block.Code));
            var fenceEnd = markdown.IndexOf("```", start + block.Code.Length, StringComparison.Ordinal);
            position = fenceEnd < 0 ? markdown.Length : fenceEnd + 3;
        }

        if (position < markdown.Length)
        {
            panel.Children.Add(Prose(markdown[position..]));
        }

        return Bubble(panel, isUser: false);
    }

    private static TextBlock Prose(string text) => new() { Text = text.Trim(), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    private Border CodeCard(string code)
    {
        var insert = new HyperlinkButton { Content = Strings.Get("Panes/AssistantInsert"), Padding = new Thickness(4, 0, 4, 0) };
        insert.Click += (_, _) => _insert(code);
        var copy = new HyperlinkButton { Content = Strings.Get("Common/Copy"),Padding = new Thickness(4, 0, 4, 0) };
        copy.Click += (_, _) => GridCommands.SetClipboard(code);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(insert);
        buttons.Children.Add(copy);
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(new TextBlock { Text = code.TrimEnd(), FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"], FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        panel.Children.Add(buttons);
        return new Border
        {
            Child = panel,
            Padding = new Thickness(10, 8, 10, 4),
            CornerRadius = new CornerRadius(6),
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1),
        };
    }

    private static Border Bubble(string text, bool isUser, bool muted = false) =>
        Bubble(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Opacity = muted ? 0.7 : 1 }, isUser);

    private static Border Bubble(UIElement content, bool isUser) => new()
    {
        Child = content,
        Padding = new Thickness(12, 8, 12, 8),
        CornerRadius = new CornerRadius(8),
        HorizontalAlignment = isUser ? HorizontalAlignment.Right : HorizontalAlignment.Stretch,
        MaxWidth = isUser ? 320 : double.PositiveInfinity,
        Background = (Brush)Application.Current.Resources[isUser ? "AccentFillColorTertiaryBrush" : "CardBackgroundFillColorDefaultBrush"],
        BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
        BorderThickness = new Thickness(isUser ? 0 : 1),
    };
}
