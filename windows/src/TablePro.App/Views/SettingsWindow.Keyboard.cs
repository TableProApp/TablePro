using System.Collections.Frozen;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Controls;
using TablePro.App.Services;
using TablePro.Core.Shortcuts;

namespace TablePro.App.Views;

/// <summary>
/// The Keyboard page: every customizable command by category, a recorder per command, conflict warnings, and reset
/// per command or for all. Changes save at once and open workspace windows rebind through the settings store.
/// </summary>
public sealed partial class SettingsWindow
{
    private const string KeyboardPage = "Keyboard";

    private ShortcutMap Keymap => new(Prefs.Shortcuts);

    private void BuildKeyboardPage(StackPanel page)
    {
        page.Children.Add(new TextBlock
        {
            Text = "Click a shortcut, then press the keys to use. Esc cancels, Backspace removes the shortcut. Editor commands work while the SQL editor has focus; the others anywhere in a connection window.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });

        var search = new AutoSuggestBox { PlaceholderText = "Search shortcuts", QueryIcon = new SymbolIcon(Symbol.Find), MinWidth = 280 };
        AutomationProperties.SetName(search, "Search shortcuts");
        var resetAll = new Button { Content = "Reset All to Defaults", HorizontalAlignment = HorizontalAlignment.Right };
        var toolbar = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 0, 0, 8) };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.Children.Add(search);
        Grid.SetColumn(resetAll, 1);
        toolbar.Children.Add(resetAll);
        page.Children.Add(toolbar);

        var message = new InfoBar { Severity = InfoBarSeverity.Warning, IsClosable = true, IsOpen = false, Margin = new Thickness(0, 0, 0, 8) };
        page.Children.Add(message);

        var list = new StackPanel { Spacing = 4 };
        page.Children.Add(list);

        void Refresh(string? focusId = null)
        {
            var map = Keymap;
            resetAll.IsEnabled = map.Overrides.Count > 0;
            list.Children.Clear();
            ShortcutRecorder? focus = null;
            foreach (var category in Enum.GetValues<ShortcutCategory>())
            {
                var header = false;
                foreach (var command in ShortcutCatalog.InCategory(category))
                {
                    if (!map.Matches(command, search.Text))
                    {
                        continue;
                    }

                    if (!header)
                    {
                        list.Children.Add(new TextBlock
                        {
                            Text = category.DisplayName(),
                            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
                            Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 20, 0, 4),
                        });
                        header = true;
                    }

                    var (row, recorder) = ShortcutRow(command, map, Change);
                    list.Children.Add(row);
                    if (command.Id == focusId)
                    {
                        focus = recorder;
                    }
                }
            }

            if (list.Children.Count == 0)
            {
                list.Children.Add(new TextBlock
                {
                    Text = "No shortcuts match.",
                    Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                });
            }

            // Rebuilding the rows drops focus; give it back to the recorder the user just used.
            focus?.Focus(FocusState.Keyboard);
        }

        async Task Change(ShortcutCommand command, ShortcutEdit edit)
        {
            message.IsOpen = false;
            var map = Keymap;
            switch (edit.Kind)
            {
                case ShortcutEditKind.Reset:
                    await SaveKeymap(m => m.WithDefault(command.Id));
                    break;
                case ShortcutEditKind.Clear:
                    await SaveKeymap(m => m.WithCleared(command.Id));
                    break;
                case ShortcutEditKind.Record:
                    var conflict = ShortcutConflictResolver.Resolve(edit.Chord, command, map);
                    if (conflict.IsBlocking)
                    {
                        message.Title = conflict.Kind == ShortcutConflictKind.NeedsModifier ? "Modifier key required" : "Reserved shortcut";
                        message.Message = conflict.Describe(edit.Chord);
                        message.IsOpen = true;
                        break;
                    }

                    if (conflict.Command is { } other)
                    {
                        var reassign = await new DialogService(this).ConfirmAsync(
                            "Shortcut conflict",
                            $"{conflict.Describe(edit.Chord)} Reassigning removes it from that command.",
                            "Reassign");
                        if (reassign)
                        {
                            await SaveKeymap(m => m.Reassign(command, edit.Chord, other));
                        }

                        break;
                    }

                    await SaveKeymap(m => m.WithChord(command.Id, edit.Chord));
                    break;
            }

            Refresh(command.Id);
        }

        search.TextChanged += (_, _) => Refresh();
        resetAll.Click += async (_, _) =>
        {
            message.IsOpen = false;
            await Update(s => s with { Shortcuts = FrozenDictionary<string, string>.Empty });
            Refresh();
        };
        Refresh();
    }

    /// <summary>Applies an edit to the latest stored overrides, so a change made elsewhere meanwhile is not undone.</summary>
    private Task SaveKeymap(Func<ShortcutMap, ShortcutMap> edit) =>
        Update(s => s with { Shortcuts = edit(new ShortcutMap(s.Shortcuts)).Overrides });

    private static (Border Row, ShortcutRecorder Recorder) ShortcutRow(ShortcutCommand command, ShortcutMap map, Func<ShortcutCommand, ShortcutEdit, Task> change)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        text.Children.Add(new TextBlock { Text = command.Title, Style = (Style)Application.Current.Resources["BodyTextBlockStyle"] });
        var conflict = ShortcutConflictResolver.Current(command, map);
        if (conflict.Kind != ShortcutConflictKind.None)
        {
            var warning = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var caution = (Brush)Application.Current.Resources["SystemFillColorCautionBrush"];
            warning.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = caution });
            warning.Children.Add(new TextBlock
            {
                Text = conflict.Describe(map.ChordFor(command)),
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = caution,
            });
            text.Children.Add(warning);
        }

        var recorder = new ShortcutRecorder { Chord = map.ChordFor(command), Tag = command.Id };
        AutomationProperties.SetName(recorder, $"Shortcut for {command.Title}");
        recorder.Recorded += async (_, chord) => await change(command, new ShortcutEdit(ShortcutEditKind.Record, chord));
        recorder.Cleared += async (_, _) => await change(command, new ShortcutEdit(ShortcutEditKind.Clear, KeyChord.None));

        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        if (map.IsCustomized(command.Id))
        {
            var reset = new Button
            {
                Content = new FontIcon { Glyph = "", FontSize = 14 },
                Style = (Style)Application.Current.Resources["ToolbarButtonStyle"],
            };
            var label = command.DefaultChord.IsEmpty ? "Reset to default (none)" : $"Reset to default ({command.DefaultChord})";
            AutomationProperties.SetName(reset, label);
            ToolTipService.SetToolTip(reset, label);
            reset.Click += async (_, _) => await change(command, new ShortcutEdit(ShortcutEditKind.Reset, KeyChord.None));
            controls.Children.Add(reset);
        }

        controls.Children.Add(recorder);

        var grid = new Grid { ColumnSpacing = 24, MinHeight = 44 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(text);
        Grid.SetColumn(controls, 1);
        grid.Children.Add(controls);
        var row = new Border { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = grid, Padding = new Thickness(16, 8, 16, 8) };
        return (row, recorder);
    }

    private enum ShortcutEditKind
    {
        Record,
        Clear,
        Reset,
    }

    private readonly record struct ShortcutEdit(ShortcutEditKind Kind, KeyChord Chord);
}
