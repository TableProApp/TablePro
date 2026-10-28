using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.Ai;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.Storage.Secrets;
using TablePro.Storage.Settings;

namespace TablePro.App.Views;

/// <summary>
/// Preferences laid out as Windows Settings is: a navigation pane of categories and a column of setting cards. Every
/// change saves at once; open windows follow through the settings store's Changed event.
/// </summary>
public sealed partial class SettingsWindow : Window
{
    private readonly AppHost _host;
    private readonly ContentControl _page = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Grid _titleBar = new() { Height = 48, Padding = new Thickness(16, 0, 0, 0) };

    public SettingsWindow(AppHost host)
    {
        _host = host;
        Title = "Settings - TablePro";
        var navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsSettingsVisible = false,
            OpenPaneLength = 240,
            Content = new ScrollViewer { Content = _page, Padding = new Thickness(32, 0, 32, 32) },
        };
        foreach (var (name, glyph) in new[] { ("General", ""), ("Editor", ""), ("Data", ""), ("AI", ""), ("MCP", "") })
        {
            navigation.MenuItems.Add(new NavigationViewItem { Content = name, Tag = name, Icon = new FontIcon { Glyph = glyph } });
        }

        navigation.SelectionChanged += (_, args) => ShowPage((args.SelectedItem as NavigationViewItem)?.Tag as string ?? "General");
        _titleBar.Children.Add(new TextBlock { Text = "Settings", VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(_titleBar);
        Grid.SetRow(navigation, 1);
        root.Children.Add(navigation);
        Content = root;
        WindowChrome.Apply(this, _titleBar, host.Backdrop, host.Theme, 960, 720);
        navigation.SelectedItem = navigation.MenuItems[0];
    }

    private AppSettings Prefs => _host.Settings.Current;

    public void ApplyAppearance(BackdropKind backdrop, ElementTheme theme)
    {
        WindowChrome.ApplyBackdrop(this, backdrop);
        WindowChrome.ApplyTheme(this, theme);
    }

    private Task Update(Func<AppSettings, AppSettings> change) => _host.Settings.UpdateAsync(change);

    private void ShowPage(string name)
    {
        var page = new StackPanel { Spacing = 4, MaxWidth = 900 };
        page.Children.Add(new TextBlock { Text = name, Style = (Style)Application.Current.Resources["TitleTextBlockStyle"], Margin = new Thickness(0, 8, 0, 20) });
        switch (name)
        {
            case "General":
                page.Children.Add(Card("App theme", "Light, dark, or follow Windows.", Choice(["Use system setting", "Light", "Dark"], (int)Prefs.Theme, i => Update(s => s with { Theme = (AppTheme)i }))));
                page.Children.Add(Card("Window material", "Acrylic shows the desktop through the window, Mica tints it with the wallpaper.", Choice(
                    ["Mica", "Acrylic", "None", "Mica Alt"], (int)Prefs.Backdrop, i => Update(s => s with { Backdrop = (WindowBackdrop)i }))));
                page.Children.Add(Card("Reopen tabs on launch", "Restore each connection's open tabs the next time it connects.", Toggle(Prefs.RestoreSessionOnLaunch, v => Update(s => s with { RestoreSessionOnLaunch = v }))));
                page.Children.Add(Card("Ask before closing unsaved tabs", null, Toggle(Prefs.ConfirmCloseDirtyTabs, v => Update(s => s with { ConfirmCloseDirtyTabs = v }))));
                page.Children.Add(Card("Data folder", Storage.AppPaths.Default.Root, OpenFolderButton(Storage.AppPaths.Default.Root)));
                break;
            case "Editor":
                page.Children.Add(Card("Font", "A monospaced font installed on this PC.", Text(Prefs.Editor.FontFamily, v => Update(s => s with { Editor = s.Editor with { FontFamily = v } }))));
                page.Children.Add(Card("Font size", null, Number(Prefs.Editor.FontSize, 8, 32, v => Update(s => s with { Editor = s.Editor with { FontSize = v } }))));
                page.Children.Add(Card("Tab size", null, Number(Prefs.Editor.TabSize, 1, 8, v => Update(s => s with { Editor = s.Editor with { TabSize = (int)v } }))));
                page.Children.Add(Card("Word wrap", null, Toggle(Prefs.Editor.WordWrap, v => Update(s => s with { Editor = s.Editor with { WordWrap = v } }))));
                page.Children.Add(Card("Autocomplete", "Suggest keywords, tables and columns while typing.", Toggle(Prefs.Editor.Autocomplete, v => Update(s => s with { Editor = s.Editor with { Autocomplete = v } }))));
                page.Children.Add(Card("Vim keybindings", "Edit with Vim's modes, motions, operators, registers and macros. Ctrl+C, Ctrl+V, Ctrl+Z and the other Windows shortcuts keep working.", Toggle(Prefs.Editor.VimMode, v => Update(s => s with { Editor = s.Editor with { VimMode = v } }))));
                break;
            case "Data":
                page.Children.Add(Card("Query result limit", "Rows an editor query reads before it stops. The status bar says when a result was cut.", Number(Prefs.Data.EditorRowLimit, 100, 1_000_000, v => Update(s => s with { Data = s.Data with { EditorRowLimit = (int)v } }))));
                page.Children.Add(Card("Table page size", "Rows a table tab shows per page.", Number(Prefs.Data.TablePageSize, 50, 100_000, v => Update(s => s with { Data = s.Data with { TablePageSize = (int)v } }))));
                page.Children.Add(Card("NULL display", "What empty cells show.", Text(Prefs.Data.NullDisplayText, v => Update(s => s with { Data = s.Data with { NullDisplayText = v } }))));
                page.Children.Add(Card("Date format", ".NET format string for dates in exports.", Text(Prefs.Data.DateFormat, v => Update(s => s with { Data = s.Data with { DateFormat = v } }))));
                page.Children.Add(Card("Query history", "Kept in a local SQLite database.", ClearHistoryButton()));
                break;
            case "AI":
                BuildAiPage(page);
                break;
            case "MCP":
                BuildMcpPage(page);
                break;
        }

        _page.Content = page;
    }

    private void BuildAiPage(StackPanel page)
    {
        var ai = Prefs.Ai;
        page.Children.Add(new TextBlock
        {
            Text = "The assistant sends your questions, the SQL it acts on and the structure of the tables involved to the provider you choose. It never sends rows. Each connection's AI setting decides whether it may be used.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        page.Children.Add(Card("Provider", null, Choice(["Anthropic", "OpenAI", "Ollama", "OpenAI-compatible server", "Google Gemini"], (int)ai.Provider, async i =>
        {
            await Update(s => s with { Ai = s.Ai with { Provider = (AiProvider)i, Model = null } });
            ShowPage("AI");
        })));
        var key = new PasswordBox { Width = 320, Password = _host.Secrets.Get(SecretKeys.Ai(ai.Provider.ToString())) ?? string.Empty, PlaceholderText = ai.Provider is AiProvider.Ollama ? "Not needed for Ollama" : "API key" };
        key.LostFocus += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(key.Password))
            {
                _host.Secrets.Delete(SecretKeys.Ai(ai.Provider.ToString()));
            }
            else
            {
                _host.Secrets.Set(SecretKeys.Ai(ai.Provider.ToString()), key.Password.Trim());
            }
        };
        page.Children.Add(Card("API key", "Stored in Windows Credential Manager.", key));
        page.Children.Add(Card("Endpoint", "Leave empty for the provider's public address. Ollama defaults to http://localhost:11434/v1.", Text(ai.Endpoint ?? string.Empty, v => Update(s => s with { Ai = s.Ai with { Endpoint = string.IsNullOrWhiteSpace(v) ? null : v.Trim() } }))));
        var model = new ComboBox { IsEditable = true, Width = 320, Text = ai.Model ?? string.Empty, PlaceholderText = "Provider default" };
        model.LostFocus += async (_, _) => await Update(s => s with { Ai = s.Ai with { Model = string.IsNullOrWhiteSpace(model.Text) ? null : model.Text.Trim() } });
        var load = new Button { Content = "Load models" };
        load.Click += async (_, _) =>
        {
            try
            {
                var (service, problem) = _host.CreateAssistant(new DialogService(this));
                if (service is null)
                {
                    model.PlaceholderText = problem ?? "Not set up";
                    return;
                }

                var models = await service.Provider.ListModelsAsync(CancellationToken.None);
                model.ItemsSource = models.Select(m => m.Id).ToList();
                model.IsDropDownOpen = true;
            }
            catch (Exception ex) when (ex is HttpRequestException or AiProviderException or InvalidOperationException)
            {
                model.PlaceholderText = ex.Message;
            }
        };
        var modelRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        modelRow.Children.Add(model);
        modelRow.Children.Add(load);
        page.Children.Add(Card("Model", null, modelRow));
        page.Children.Add(Card("Suggest while typing", "Asks for a completion when you pause at the end of a line. Each pause sends the text around the cursor.", Toggle(ai.InlineSuggestions, v => Update(s => s with { Ai = s.Ai with { InlineSuggestions = v } }))));
    }

    private void BuildMcpPage(StackPanel page)
    {
        var mcp = Prefs.Mcp;
        page.Children.Add(new TextBlock
        {
            Text = "MCP clients on this computer, such as Claude Code or Cursor, can use your saved connections through TablePro. The server listens on 127.0.0.1 only, while TablePro runs. Each connection's External Clients level decides what a client may do.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        void Refresh()
        {
            var server = _host.McpServer;
            status.Text = server is { IsRunning: true }
                ? $"Running at {server.Endpoint}\n\nclaude mcp add --transport http tablepro {server.Endpoint} --header \"Authorization: Bearer {server.Token.Value}\""
                : "Stopped";
        }

        page.Children.Add(Card("Enable MCP server", null, Toggle(mcp.Enabled, async v =>
        {
            await Update(s => s with { Mcp = s.Mcp with { Enabled = v } });
            try
            {
                await _host.ApplyMcpAsync();
            }
            catch (Exception ex) when (ex is Mcp.McpPortInUseException or IOException or InvalidOperationException)
            {
                status.Text = ex.Message;
                return;
            }

            Refresh();
        })));
        page.Children.Add(Card("Port", null, Number(mcp.Port, 1024, 65535, async v =>
        {
            await Update(s => s with { Mcp = s.Mcp with { Port = (int)v } });
            if (Prefs.Mcp.Enabled)
            {
                await _host.ApplyMcpAsync();
                Refresh();
            }
        })));
        var regenerate = new Button { Content = "Regenerate access token" };
        regenerate.Click += (_, _) =>
        {
            _host.RegenerateMcpToken();
            Refresh();
        };
        var copy = new Button { Content = "Copy command" };
        copy.Click += (_, _) => GridCommands.SetClipboard(status.Text);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(copy);
        buttons.Children.Add(regenerate);
        page.Children.Add(Card("Status", null, buttons));
        page.Children.Add(new Border { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = status, Margin = new Thickness(0, 4, 0, 0) });
        Refresh();
    }

    private static Border Card(string title, string? description, FrameworkElement control)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        text.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["BodyTextBlockStyle"] });
        if (!string.IsNullOrEmpty(description))
        {
            text.Children.Add(new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        }

        var grid = new Grid { ColumnSpacing = 24, MinHeight = 44 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(text);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return new Border { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = grid, Padding = new Thickness(16, 12, 16, 12) };
    }

    private static ComboBox Choice(string[] options, int selected, Func<int, Task> changed)
    {
        var box = new ComboBox { MinWidth = 220, ItemsSource = options, SelectedIndex = Math.Clamp(selected, 0, options.Length - 1) };
        box.SelectionChanged += async (_, _) => await changed(box.SelectedIndex);
        return box;
    }

    private static ToggleSwitch Toggle(bool value, Func<bool, Task> changed)
    {
        var toggle = new ToggleSwitch { IsOn = value, OnContent = "On", OffContent = "Off", MinWidth = 0 };
        toggle.Toggled += async (_, _) => await changed(toggle.IsOn);
        return toggle;
    }

    private static TextBox Text(string value, Func<string, Task> changed)
    {
        var box = new TextBox { Text = value, Width = 320 };
        box.LostFocus += async (_, _) => await changed(box.Text);
        return box;
    }

    private static NumberBox Number(double value, double min, double max, Func<double, Task> changed)
    {
        var box = new NumberBox { Value = value, Minimum = min, Maximum = max, Width = 160, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        box.ValueChanged += async (_, args) =>
        {
            if (!double.IsNaN(args.NewValue))
            {
                await changed(args.NewValue);
            }
        };
        return box;
    }

    private static Button OpenFolderButton(string path)
    {
        var button = new Button { Content = "Open folder" };
        button.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        return button;
    }

    private Button ClearHistoryButton()
    {
        var button = new Button { Content = "Clear all history" };
        button.Click += async (_, _) =>
        {
            if (await new DialogService(this).ConfirmAsync("Clear history?", "Every connection's query history is deleted.", "Clear", destructive: true))
            {
                await _host.History.ClearAsync(null);
            }
        };
        return button;
    }
}
