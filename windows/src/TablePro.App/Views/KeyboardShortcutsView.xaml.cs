using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls;
using TablePro.App.Model;
using TablePro.App.Services;

namespace TablePro.App.Views;

// Rebinding one shortcut at a time, a mirror of macOS KeyboardSettingsView. A page swapped into the window as Settings
// is (windows/docs/decisions/0025 and 0028): the preset on top, then a recorder per rebindable command. The customs
// live in AppSettings; DisplaySettings lays them over the preset and the menus follow at once.
public sealed partial class KeyboardShortcutsView : UserControl
{
    // Groups in the order a user scans them; the rebindable commands fall into these scopes.
    private static readonly CommandScope[] Groups =
    [
        CommandScope.Global,
        CommandScope.Workspace,
        CommandScope.QueryTab,
        CommandScope.TableTab,
        CommandScope.Editor,
        CommandScope.Grid,
    ];

    private readonly Workbench _workbench;
    private readonly Dictionary<string, Row> _rows = new(StringComparer.Ordinal);
    private bool _loading;

    internal KeyboardShortcutsView(Workbench workbench)
    {
        _workbench = workbench;
        InitializeComponent();
        BuildRows();
        Unloaded += (_, _) =>
        {
            foreach (var row in _rows.Values)
            {
                row.Recorder.Cancel();
            }
        };
    }

    // Read again each time the page comes back, as the preset or a custom may have changed elsewhere.
    public void Refresh()
    {
        _loading = true;
        var settings = _workbench.Settings;
        SettingsView.FillPresets(PresetBox, settings.ShortcutPreset);
        var overrides = ShortcutOverrides.From(settings.ShortcutOverrides);
        foreach (var (action, row) in _rows)
        {
            row.Card.Description = null;
            row.Recorder.Configure(action, Strings.Get(Keymap.NameKey(action)), Label(action));
            row.Reset.Visibility = overrides.IsCustomized(action) ? Visibility.Visible : Visibility.Collapsed;
        }

        SummaryText.Text = Summary(settings, overrides);
        RestoreButton.IsEnabled = overrides.Count > 0;
        _loading = false;
    }

    private static string Word(string id) => Strings.Get("Key_" + id);

    private static string? Label(string action) =>
        DisplaySettings.Keymap.KeysOf(action) is [var first, ..] ? EffectiveKeymap.Text(first, Word) : null;

    private static string Summary(AppSettings settings, ShortcutOverrides overrides)
    {
        if (overrides.Count > 0)
        {
            return Strings.Plural("ShortcutSummaryCustom", overrides.Count, overrides.Count);
        }

        if (settings.ShortcutPreset is { } id
            && PresetName(id) is { } name)
        {
            return Strings.Format("ShortcutSummaryPreset", name);
        }

        return Strings.Get("ShortcutSummaryNone");
    }

    private static string? PresetName(string id)
    {
        try
        {
            return TablePro.Interop.TableProCore.KeymapPresets(TablePro.Interop.KeymapPlatform.Windows)
                .FirstOrDefault(preset => preset.Id == id)?.Name;
        }
        catch (TablePro.Interop.TableProException)
        {
            return null;
        }
    }

    private void BuildRows()
    {
        foreach (var scope in Groups)
        {
            var commands = Keymap.Rebindable.Where(command => command.Scope == scope).ToList();
            if (commands.Count == 0)
            {
                continue;
            }

            var header = new TextBlock
            {
                Text = Strings.Get(Keymap.GroupKey(scope)),
                Style = (Style)Application.Current.Resources["SettingsSectionHeaderStyle"],
                Margin = new Thickness(1, 8, 0, 4),
            };
            AutomationProperties.SetHeadingLevel(header, AutomationHeadingLevel.Level2);
            RowsHost.Children.Add(header);
            foreach (var command in commands)
            {
                RowsHost.Children.Add(BuildRow(command.Action));
            }
        }
    }

    private SettingsCard BuildRow(string action)
    {
        var recorder = new ShortcutRecorderButton();
        recorder.Captured += async (_, chord) => await OnCapturedAsync(action, chord).ConfigureAwait(true);
        recorder.RemoveRequested += (_, _) => Apply(ShortcutOverrides.From(_workbench.Settings.ShortcutOverrides).Clearing(action));

        var reset = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 14 },
            Visibility = Visibility.Collapsed,
            Width = 36,
        };
        AutomationProperties.SetName(reset, Strings.Format("ShortcutResetName", Strings.Get(Keymap.NameKey(action))));
        AutomationProperties.SetAutomationId(reset, "shortcut-reset-" + action);
        ToolTipService.SetToolTip(reset, Strings.Get("ShortcutResetTip"));
        reset.Click += (_, _) => Apply(ShortcutOverrides.From(_workbench.Settings.ShortcutOverrides).Resetting(action));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(reset);
        actions.Children.Add(recorder);

        var card = new SettingsCard { Header = Strings.Get(Keymap.NameKey(action)), Content = actions };
        _rows[action] = new Row(card, recorder, reset);
        return card;
    }

    private async Task OnCapturedAsync(string action, KeyChord chord)
    {
        var decision = Keymap.Classify(action, chord, DisplaySettings.Keymap);
        switch (decision.Kind)
        {
            case ShortcutCapture.Capture:
                Apply(ShortcutOverrides.From(_workbench.Settings.ShortcutOverrides).Assigning(action, chord));
                break;
            case ShortcutCapture.Reassign:
                await ConfirmReassignAsync(decision).ConfigureAwait(true);
                break;
            default:
                if (_rows.TryGetValue(action, out var row))
                {
                    row.Card.Description = Refusal(decision);
                }

                break;
        }
    }

    private async Task ConfirmReassignAsync(ShortcutDecision decision)
    {
        var chord = EffectiveKeymap.Text(decision.Chord, Word);
        var names = decision.Holders.Select(holder => Strings.Get(Keymap.NameKey(holder))).ToList();
        var who = names.Count == 1 ? names[0] : Strings.List(names);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Format("ShortcutReassignTitle", chord),
            Content = Strings.Plural("ShortcutReassignUsedBy", names.Count, who),
            PrimaryButtonText = Strings.Get("ShortcutReassign"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) == ContentDialogResult.Primary)
        {
            Apply(ShortcutOverrides.From(_workbench.Settings.ShortcutOverrides)
                .Reassigning(decision.Action, decision.Chord, decision.Holders));
        }
    }

    private static string Refusal(ShortcutDecision decision) => decision.Reason switch
    {
        ShortcutRefusal.NeedsModifier => Strings.Get("ShortcutRefusal_NeedsModifier"),
        ShortcutRefusal.UnavailableKey => Strings.Get("ShortcutRefusal_UnavailableKey"),
        _ => Strings.Format("ShortcutRefusal_Reserved", EffectiveKeymap.Text(decision.Chord, Word)),
    };

    private void Apply(ShortcutOverrides overrides)
    {
        _workbench.UpdateSettings(settings => settings with { ShortcutOverrides = overrides.ToStorage() });
        Refresh();
    }

    private void OnPresetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && PresetBox.SelectedItem is ComboBoxItem { Tag: string id })
        {
            _workbench.UpdateSettings(settings => settings with { ShortcutPreset = id.Length == 0 ? null : id });
            Refresh();
        }
    }

    // Every custom goes; the preset stays, so the keys fall back to it.
    private async void OnRestore(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("ShortcutRestoreTitle"),
            Content = Strings.Get("ShortcutRestoreMessage"),
            PrimaryButtonText = Strings.Get("ShortcutRestoreConfirm"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) == ContentDialogResult.Primary)
        {
            Apply(ShortcutOverrides.None);
        }
    }

    private sealed record Row(SettingsCard Card, ShortcutRecorderButton Recorder, Button Reset);
}
