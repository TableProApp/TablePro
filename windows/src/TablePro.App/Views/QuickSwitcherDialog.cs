using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using Windows.System;

namespace TablePro.App.Views;

/// <summary>The Open Quickly panel: type to filter, arrows to move, Enter to open, Shift+Enter for a table's structure.</summary>
internal static class QuickSwitcherDialog
{
    public static async Task ShowAsync(DialogService dialogs, WorkspaceViewModel workspace)
    {
        var viewModel = new QuickSwitcherViewModel(workspace);
        var box = new TextBox { PlaceholderText = Strings.Get("Panes/QuickSwitcherPlaceholder") };
        AutomationProperties.SetName(box, Strings.Get("Panes/QuickSwitcherTitle"));
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true,
            Height = 380,
            Margin = new Thickness(0, 8, 0, 0),
            ItemContainerStyle = StretchedItems(),
        };
        var empty = new TextBlock
        {
            Text = Strings.Get("Panes/QuickSwitcherNoMatches"),
            Margin = new Thickness(0, 16, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        var panel = new Grid { Width = 560 };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.Children.Add(box);
        Grid.SetRow(list, 1);
        Grid.SetRow(empty, 1);
        panel.Children.Add(list);
        panel.Children.Add(empty);

        var dialog = dialogs.Create(Strings.Get("Panes/QuickSwitcherTitle"), panel, null, Strings.Get("Common/Close"));

        // ContentDialog caps its width at 548 by default, which would clip the kind column.
        dialog.Resources["ContentDialogMaxWidth"] = 640.0;
        QuickSwitcherItem? chosen = null;
        var structure = false;

        void Render()
        {
            list.Items.Clear();
            foreach (var item in viewModel.Results)
            {
                list.Items.Add(Row(panel, item));
            }

            empty.Visibility = viewModel.Results.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            SyncSelection();
        }

        void SyncSelection()
        {
            if (viewModel.SelectedIndex >= 0 && viewModel.SelectedIndex < list.Items.Count)
            {
                list.SelectedIndex = viewModel.SelectedIndex;
                list.ScrollIntoView(list.Items[viewModel.SelectedIndex]);
            }
        }

        void Choose(QuickSwitcherItem? item, bool openStructure)
        {
            chosen = item;
            structure = openStructure;
            dialog.Hide();
        }

        box.TextChanged += (_, _) =>
        {
            viewModel.Query = box.Text;
            Render();
        };
        box.PreviewKeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case VirtualKey.Down:
                    viewModel.Move(1);
                    break;
                case VirtualKey.Up:
                    viewModel.Move(-1);
                    break;
                case VirtualKey.PageDown:
                    viewModel.Move(10);
                    break;
                case VirtualKey.PageUp:
                    viewModel.Move(-10);
                    break;
                case VirtualKey.Enter:
                    var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                    Choose(viewModel.Selected, shift);
                    break;
                default:
                    return;
            }

            e.Handled = true;
            SyncSelection();
        };
        list.ItemClick += (_, e) => Choose((e.ClickedItem as FrameworkElement)?.Tag as QuickSwitcherItem, false);
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);

        Render();
        await dialogs.ShowAsync(dialog);
        if (chosen is not null)
        {
            viewModel.Commit(chosen, structure);
        }
    }

    private static Style StretchedItems()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        return style;
    }

    private static Grid Row(FrameworkElement theme, QuickSwitcherItem item)
    {
        var secondary = ThemeResources.Brush(theme, "TextFillColorSecondaryBrush");
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6), Tag = item };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        row.Children.Add(new FontIcon { Glyph = item.Glyph, FontSize = 14, Foreground = secondary, VerticalAlignment = VerticalAlignment.Center });

        var name = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis };
        AddHighlighted(name, item);
        if (item.Location.Length > 0)
        {
            name.Inlines.Add(new Run { Text = "  " + item.Location, Foreground = secondary, FontSize = 12 });
        }

        Grid.SetColumn(name, 1);
        row.Children.Add(name);

        var kind = new TextBlock { Text = item.KindText, Foreground = secondary, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(kind, 2);
        row.Children.Add(kind);
        AutomationProperties.SetName(row, Strings.Format("Panes/QuickSwitcherRowName", item.Name, item.KindText));
        return row;
    }

    // Matched letters are bold, the way the macOS panel marks why a row matched.
    private static void AddHighlighted(TextBlock block, QuickSwitcherItem item)
    {
        var text = item.Name;
        var start = 0;
        var i = 0;
        while (i < text.Length)
        {
            var bold = item.Matched.Contains(i);
            var end = i;
            while (end < text.Length && item.Matched.Contains(end) == bold)
            {
                end++;
            }

            if (end > start)
            {
                block.Inlines.Add(new Run { Text = text[start..end], FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal });
            }

            start = i = end;
        }
    }
}
