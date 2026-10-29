using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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
        Title = Strings.Get("Settings/WindowTitle");
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
            navigation.MenuItems.Add(new NavigationViewItem { Content = PageTitle(name), Tag = name, Icon = new FontIcon { Glyph = glyph } });
        }

        navigation.MenuItems.Insert(2, new NavigationViewItem { Content = PageTitle(KeyboardPage), Tag = KeyboardPage, Icon = new FontIcon { Glyph = "" } });
        navigation.SelectionChanged += (_, args) => ShowPage((args.SelectedItem as NavigationViewItem)?.Tag as string ?? "General");
        _titleBar.Children.Add(new TextBlock { Text = Strings.Get("Common/Settings"),VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
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

    /// <summary>A page's heading, looked up by its tag, which stays English because it names the page in code.</summary>
    private static string PageTitle(string name) => Strings.Get("Settings/Page" + name);

    private void ShowPage(string name)
    {
        var page = new StackPanel { Spacing = 4, MaxWidth = 900 };
        page.Children.Add(new TextBlock { Text = PageTitle(name), Style = (Style)Application.Current.Resources["TitleTextBlockStyle"], Margin = new Thickness(0, 8, 0, 20) });
        switch (name)
        {
            case "General":
                page.Children.Add(Card(Strings.Get("Settings/LanguageTitle"), Strings.Get("Settings/LanguageDescription"), LanguageChoice()));
                page.Children.Add(Card(Strings.Get("Settings/ThemeTitle"), Strings.Get("Settings/ThemeDescription"), Choice([Strings.Get("Settings/UseSystemSetting"), Strings.Get("Settings/ThemeLight"), Strings.Get("Settings/ThemeDark")], (int)Prefs.Theme, i => Update(s => s with { Theme = (AppTheme)i }))));
                page.Children.Add(Card(Strings.Get("Settings/BackdropTitle"), Strings.Get("Settings/BackdropDescription"), Choice(
                    [Strings.Get("Settings/BackdropMica"), Strings.Get("Settings/BackdropAcrylic"), Strings.Get("Common/None"), Strings.Get("Settings/BackdropMicaAlt")], (int)Prefs.Backdrop, i => Update(s => s with { Backdrop = (WindowBackdrop)i }))));
                page.Children.Add(Card(Strings.Get("Settings/RestoreTabsTitle"), Strings.Get("Settings/RestoreTabsDescription"), Toggle(Prefs.RestoreSessionOnLaunch, v => Update(s => s with { RestoreSessionOnLaunch = v }))));
                page.Children.Add(Card(Strings.Get("Settings/ConfirmCloseTitle"), null, Toggle(Prefs.ConfirmCloseDirtyTabs, v => Update(s => s with { ConfirmCloseDirtyTabs = v }))));
                page.Children.Add(Card(Strings.Get("Settings/RewindJournalTitle"), Strings.Get("Settings/RewindJournalDescription"), Toggle(Prefs.KeepRewindJournal, async v =>
                {
                    RewindJournalService.Enabled = v;
                    await Update(s => s with { KeepRewindJournal = v });
                })));
                page.Children.Add(Card(Strings.Get("Settings/SavedChangesTitle"), Strings.Get("Settings/SavedChangesDescription"), ClearRewindButton()));
                AddUpdateCards(page);
                page.Children.Add(Card(Strings.Get("Settings/DataFolderTitle"), Storage.AppPaths.Default.Root, OpenFolderButton(Storage.AppPaths.Default.Root)));
                break;
            case "Editor":
                page.Children.Add(Card(Strings.Get("Settings/FontTitle"), Strings.Get("Settings/FontDescription"), Text(Prefs.Editor.FontFamily, v => Update(s => s with { Editor = s.Editor with { FontFamily = v } }))));
                page.Children.Add(Card(Strings.Get("Settings/FontSizeTitle"), null, Number(Prefs.Editor.FontSize, 8, 32, v => Update(s => s with { Editor = s.Editor with { FontSize = v } }))));
                page.Children.Add(Card(Strings.Get("Settings/TabSizeTitle"), null, Number(Prefs.Editor.TabSize, 1, 8, v => Update(s => s with { Editor = s.Editor with { TabSize = (int)v } }))));
                page.Children.Add(Card(Strings.Get("Settings/WordWrapTitle"), null, Toggle(Prefs.Editor.WordWrap, v => Update(s => s with { Editor = s.Editor with { WordWrap = v } }))));
                page.Children.Add(Card(Strings.Get("Settings/AutocompleteTitle"), Strings.Get("Settings/AutocompleteDescription"), Toggle(Prefs.Editor.Autocomplete, v => Update(s => s with { Editor = s.Editor with { Autocomplete = v } }))));
                AddKeyBindingCards(page);
                break;
            case "Data":
                page.Children.Add(Card(Strings.Get("Settings/RowLimitTitle"), Strings.Get("Settings/RowLimitDescription"), Number(Prefs.Data.EditorRowLimit, 100, 1_000_000, v => Update(s => s with { Data = s.Data with { EditorRowLimit = (int)v } }))));
                page.Children.Add(Card(Strings.Get("Settings/PageSizeTitle"), Strings.Get("Settings/PageSizeDescription"), Number(Prefs.Data.TablePageSize, 50, 100_000, v => Update(s => s with { Data = s.Data with { TablePageSize = (int)v } }))));
                page.Children.Add(Card(Strings.Get("Settings/NullDisplayTitle"), Strings.Get("Settings/NullDisplayDescription"), Text(Prefs.Data.NullDisplayText, v => Update(s => s with { Data = s.Data with { NullDisplayText = v } }))));
                page.Children.Add(Card(Strings.Get("Settings/DateFormatTitle"), Strings.Get("Settings/DateFormatDescription"), Text(Prefs.Data.DateFormat, v => Update(s => s with { Data = s.Data with { DateFormat = v } }))));
                page.Children.Add(Card(Strings.Get("Settings/QueryHistoryTitle"), Strings.Get("Settings/QueryHistoryDescription"), ClearHistoryButton()));
                break;
            case KeyboardPage:
                BuildKeyboardPage(page);
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

    /// <summary>
    /// Vim and Emacs bindings, one at most, as macOS offers them in one picker: turning one on turns the other off in
    /// the same save, so the two never race to write the file.
    /// </summary>
    private void AddKeyBindingCards(StackPanel page)
    {
        var editor = Prefs.Editor;
        var syncing = false;
        var vim = Toggle(editor.VimMode, v => syncing ? Task.CompletedTask : Update(s => s with { Editor = s.Editor with { VimMode = v, EmacsKeys = !v && s.Editor.EmacsKeys } }));
        var emacs = Toggle(editor.EmacsKeys && !editor.VimMode, v => syncing ? Task.CompletedTask : Update(s => s with { Editor = s.Editor with { EmacsKeys = v, VimMode = !v && s.Editor.VimMode } }));
        vim.Toggled += (_, _) => TurnOff(vim, emacs);
        emacs.Toggled += (_, _) => TurnOff(emacs, vim);
        page.Children.Add(Card(Strings.Get("Settings/VimTitle"), Strings.Get("Settings/VimDescription"), vim));
        page.Children.Add(Card(Strings.Get("Settings/EmacsTitle"), Strings.Get("Settings/EmacsDescription"), emacs));

        void TurnOff(ToggleSwitch changed, ToggleSwitch other)
        {
            if (!changed.IsOn || !other.IsOn)
            {
                return;
            }

            syncing = true;
            other.IsOn = false;
            syncing = false;
        }
    }

    private void BuildAiPage(StackPanel page)
    {
        var ai = Prefs.Ai;
        page.Children.Add(new TextBlock
        {
            Text = Strings.Get("Settings/AiIntro"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        page.Children.Add(Card(Strings.Get("Settings/AiProviderTitle"), null, Choice(["Anthropic", "OpenAI", "Ollama", Strings.Get("Settings/AiProviderOpenAICompatible"), "Google Gemini"], (int)ai.Provider, async i =>
        {
            await Update(s => s with { Ai = s.Ai with { Provider = (AiProvider)i, Model = null } });
            ShowPage("AI");
        })));
        var key = new PasswordBox { Width = 320, Password = _host.Secrets.Get(SecretKeys.Ai(ai.Provider.ToString())) ?? string.Empty, PlaceholderText = ai.Provider is AiProvider.Ollama ? Strings.Get("Settings/AiKeyNotNeeded") : Strings.Get("Settings/AiKeyTitle") };
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
        page.Children.Add(Card(Strings.Get("Settings/AiKeyTitle"), Strings.Get("Settings/AiKeyDescription"), key));
        page.Children.Add(Card(Strings.Get("Settings/AiEndpointTitle"), Strings.Get("Settings/AiEndpointDescription"), Text(ai.Endpoint ?? string.Empty, v => Update(s => s with { Ai = s.Ai with { Endpoint = string.IsNullOrWhiteSpace(v) ? null : v.Trim() } }))));
        var model = new ComboBox { IsEditable = true, Width = 320, Text = ai.Model ?? string.Empty, PlaceholderText = Strings.Get("Settings/AiModelDefault") };
        model.LostFocus += async (_, _) => await Update(s => s with { Ai = s.Ai with { Model = string.IsNullOrWhiteSpace(model.Text) ? null : model.Text.Trim() } });
        var load = new Button { Content = Strings.Get("Settings/AiLoadModels") };
        load.Click += async (_, _) =>
        {
            try
            {
                var (service, problem) = _host.CreateAssistant(new DialogService(this));
                if (service is null)
                {
                    model.PlaceholderText = problem ?? Strings.Get("Settings/AiNotSetUp");
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
        page.Children.Add(Card(Strings.Get("Settings/AiModelTitle"), null, modelRow));
        page.Children.Add(Card(Strings.Get("Settings/AiSuggestTitle"), Strings.Get("Settings/AiSuggestDescription"), Toggle(ai.InlineSuggestions, v => Update(s => s with { Ai = s.Ai with { InlineSuggestions = v } }))));
    }

    private void BuildMcpPage(StackPanel page)
    {
        var mcp = Prefs.Mcp;
        page.Children.Add(new TextBlock
        {
            Text = Strings.Get("Settings/McpIntro"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        void Refresh()
        {
            var server = _host.McpServer;
            status.Text = server is { IsRunning: true }
                ? Strings.Format("Settings/McpRunningAt", server.Endpoint) + $"\n\nclaude mcp add --transport http tablepro {server.Endpoint} --header \"Authorization: Bearer {server.Token.Value}\""
                : Strings.Get("Settings/McpStopped");
        }

        page.Children.Add(Card(Strings.Get("Settings/McpEnableTitle"), null, Toggle(mcp.Enabled, async v =>
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
        page.Children.Add(Card(Strings.Get("Settings/McpPortTitle"), null, Number(mcp.Port, 1024, 65535, async v =>
        {
            await Update(s => s with { Mcp = s.Mcp with { Port = (int)v } });
            if (Prefs.Mcp.Enabled)
            {
                await _host.ApplyMcpAsync();
                Refresh();
            }
        })));
        var regenerate = new Button { Content = Strings.Get("Settings/McpRegenerateToken") };
        regenerate.Click += (_, _) =>
        {
            _host.RegenerateMcpToken();
            Refresh();
        };
        var copy = new Button { Content = Strings.Get("Settings/McpCopyCommand") };
        copy.Click += (_, _) => GridCommands.SetClipboard(status.Text);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(copy);
        buttons.Children.Add(regenerate);
        page.Children.Add(Card(Strings.Get("Settings/McpStatusTitle"), null, buttons));
        page.Children.Add(new Border { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = status, Margin = new Thickness(0, 4, 0, 0) });
        Refresh();
        page.Children.Add(new McpClientsPane(_host));
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

    /// <summary>
    /// "Use system setting" and each shipped language under its own name. XAML and MRT Core read the language once, at
    /// launch, so a change is saved for the next start and the user is offered a restart now.
    /// </summary>
    private ComboBox LanguageChoice()
    {
        var languages = AppLanguages.All;
        var options = new[] { Strings.Get("Settings/UseSystemSetting") }.Concat(languages.Select(l => l.NativeName)).ToArray();
        var selected = languages.ToList().FindIndex(l => string.Equals(l.Tag, Prefs.Language, StringComparison.OrdinalIgnoreCase)) + 1;
        var box = Choice(options, selected, async i =>
        {
            var tag = i <= 0 ? string.Empty : languages[i - 1].Tag;
            await Update(s => s with { Language = tag });
            if (!string.Equals(tag, AppLanguages.Override, StringComparison.OrdinalIgnoreCase))
            {
                await OfferRestartAsync();
            }
        });
        AutomationProperties.SetName(box, Strings.Get("Settings/LanguageTitle"));
        return box;
    }

    private async Task OfferRestartAsync()
    {
        var dialogs = new DialogService(this);
        var message = new TextBlock { Text = Strings.Get("Settings/LanguageRestartMessage"), TextWrapping = TextWrapping.Wrap };
        var dialog = dialogs.Create(Strings.Get("Settings/LanguageRestartTitle"), message, Strings.Get("Settings/RestartNow"), Strings.Get("Settings/RestartLater"));
        if (await dialogs.ShowAsync(dialog) == ContentDialogResult.Primary && await _host.ConfirmQuitAsync())
        {
            // Restart relaunches the same build, packaged or not, with the saved language applied at startup.
            var failure = Microsoft.Windows.AppLifecycle.AppInstance.Restart(string.Empty);
            CrashLog.Write("Restart after a language change failed", new InvalidOperationException(failure.ToString()));
        }
    }

    private Button ClearRewindButton()
    {
        var button = new Button { Content = Strings.Get("Common/Clear") };
        button.Click += async (_, _) =>
        {
            if (await new DialogService(this).ConfirmAsync(Strings.Get("Settings/ClearRewindConfirmTitle"), Strings.Get("Settings/ClearRewindConfirmMessage"), Strings.Get("Common/Clear"), destructive: true))
            {
                await RewindJournalService.Journal.ClearAsync();
            }
        };
        return button;
    }

    private static ComboBox Choice(string[] options, int selected, Func<int, Task> changed)
    {
        var box = new ComboBox { MinWidth = 220, ItemsSource = options, SelectedIndex = Math.Clamp(selected, 0, options.Length - 1) };
        box.SelectionChanged += async (_, _) => await changed(box.SelectedIndex);
        return box;
    }

    private static ToggleSwitch Toggle(bool value, Func<bool, Task> changed)
    {
        var toggle = new ToggleSwitch { IsOn = value, OnContent = Strings.Get("Common/On"), OffContent = Strings.Get("Common/Off"), MinWidth = 0 };
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
        var button = new Button { Content = Strings.Get("Settings/OpenFolder") };
        button.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        return button;
    }

    private Button ClearHistoryButton()
    {
        var button = new Button { Content = Strings.Get("Settings/ClearAllHistory") };
        button.Click += async (_, _) =>
        {
            if (await new DialogService(this).ConfirmAsync(Strings.Get("Settings/ClearHistoryConfirmTitle"), Strings.Get("Settings/ClearHistoryConfirmMessage"), Strings.Get("Common/Clear"), destructive: true))
            {
                await _host.History.ClearAsync(null);
            }
        };
        return button;
    }
}
