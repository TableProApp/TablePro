using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model.QuickSwitcher;
using TablePro.App.Services;
using Windows.System;

namespace TablePro.App.Views;

public sealed record PaletteCommitEventArgs(PaletteItem Item, PaletteCommitIntent Intent);

// The command palette overlay: a Popup over the owning window's Root, a search box, a scope bar and the ranked list the
// PaletteModel feeds. It mirrors the macOS QuickSwitcher panel, which WinUI has no borderless NSPanel for.
public sealed partial class CommandPalette : UserControl
{
    private readonly FrameworkElement _owner;
    private readonly PaletteModel _model;
    private readonly Popup _popup;
    private readonly CollectionViewSource _source;
    private readonly ObservableCollection<PaletteSection> _sections = [];

    public CommandPalette(FrameworkElement owner, PaletteModel model)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(model);
        _owner = owner;
        _model = model;
        InitializeComponent();

        _source = new CollectionViewSource { IsSourceGrouped = true, Source = _sections };
        Rows.ItemsSource = _source.View;
        AutomationProperties.SetName(Rows, Strings.Get("PaletteResultsName"));

        _popup = new Popup
        {
            Child = this,
            IsLightDismissEnabled = true,
            ShouldConstrainToRootBounds = false,
        };
        _popup.Closed += (_, _) => Dismissed?.Invoke(this, EventArgs.Empty);

        Search.KeyDown += OnSearchKeyDown;
        _model.GroupsChanged += (_, _) => DispatcherQueue.TryEnqueue(ShowGroups);
        _model.SelectionChanged += (_, _) => DispatcherQueue.TryEnqueue(ShowSelection);
    }

    public event EventHandler<PaletteCommitEventArgs>? Committed;

    public event EventHandler? Dismissed;

    public bool IsOpen => _popup.IsOpen;

    public void Show()
    {
        _popup.XamlRoot = _owner.XamlRoot;
        Place();
        _owner.XamlRoot.Changed += (_, _) => Place();
        _popup.IsOpen = true;
        ShowGroups();
        DispatcherQueue.TryEnqueue(() => Search.Focus(FocusState.Programmatic));
    }

    public void Dismiss() => _popup.IsOpen = false;

    private void Place()
    {
        if (_popup.XamlRoot is not { } root)
        {
            return;
        }

        _popup.HorizontalOffset = Math.Max(0, (root.Size.Width - Panel.Width) / 2);
        _popup.VerticalOffset = Math.Max(24, root.Size.Height * 0.18);
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => _model.SetSearchText(Search.Text);

    private void OnScopeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var index = sender.Items.IndexOf(sender.SelectedItem);
        if (index >= 0 && index < PaletteScopes.All.Count)
        {
            _model.SetScope(PaletteScopes.All[index]);
        }
    }

    private void OnRowClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PaletteRowView row)
        {
            Commit(row.Item, PaletteCommitIntent.Open);
        }
    }

    private void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Down:
                _model.MoveSelection(1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                _model.MoveSelection(-1);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                CommitSelected(control ? PaletteCommitIntent.OpenInNewTab : PaletteCommitIntent.Open);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                if (Search.Text.Length > 0)
                {
                    Search.Text = string.Empty;
                }
                else
                {
                    Dismiss();
                }

                e.Handled = true;
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number6 when control:
                SelectScope(e.Key - VirtualKey.Number1);
                e.Handled = true;
                break;
            default:
                break;
        }
    }

    private void SelectScope(int index)
    {
        if (index < 0 || index >= ScopeBar.Items.Count)
        {
            return;
        }

        ScopeBar.SelectedItem = ScopeBar.Items[index];
    }

    private async void CommitSelected(PaletteCommitIntent intent)
    {
        await _model.FlushAsync();
        if (_model.SelectedItem() is { } item)
        {
            Commit(item, intent);
        }
    }

    private void Commit(PaletteItem item, PaletteCommitIntent intent)
    {
        _model.RecordSelection(item);
        Dismiss();
        Committed?.Invoke(this, new PaletteCommitEventArgs(item, intent));
    }

    private void ShowGroups()
    {
        _sections.Clear();
        foreach (var group in _model.Groups)
        {
            _sections.Add(new PaletteSection(Header(group.Header), [.. group.Items.Select(item => new PaletteRowView(item))]));
        }

        var typed = _model.SearchText.Trim().Length > 0;
        NoResults.Visibility = typed && _sections.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoResults.Text = typed ? Strings.Format("PaletteNoResults", _model.SearchText.Trim()) : string.Empty;
        ShowSelection();
    }

    private void ShowSelection()
    {
        var selected = _sections
            .SelectMany(section => section)
            .FirstOrDefault(row => string.Equals(row.Item.Id, _model.SelectedId, StringComparison.Ordinal));
        Rows.SelectedItem = selected;
        if (selected is not null)
        {
            Rows.ScrollIntoView(selected);
        }
    }

    private static string Header(PaletteGroupHeader header) => header switch
    {
        PaletteGroupHeader.RecentHeader => Strings.Get("PaletteRecent"),
        PaletteGroupHeader.SectionHeader section => Strings.Get("PaletteSection_" + section.Kind),
        _ => string.Empty,
    };
}

// A group of rows under one header. CollectionViewSource groups on it, so it is a collection with a title.
internal sealed class PaletteSection(string title, IReadOnlyList<PaletteRowView> rows) : List<PaletteRowView>(rows)
{
    public string Title { get; } = title;

    public Visibility HeaderVisibility => Title.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
}

// One row's display, bound by the item template.
internal sealed class PaletteRowView(PaletteItem item)
{
    public PaletteItem Item { get; } = item;

    public string Title => Item.Name;

    public string Subtitle => Item.Subtitle;

    public string Glyph => PaletteGlyphs.For(Item.Kind);

    public Visibility SubtitleVisibility => Subtitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
}

// Segoe Fluent Icons glyphs, one per kind, matching the tree's icon choices where they overlap.
internal static class PaletteGlyphs
{
    public static string For(PaletteItemKind kind) => kind switch
    {
        PaletteItemKind.Table or PaletteItemKind.SystemTable => "",
        PaletteItemKind.View => "",
        PaletteItemKind.Database => "",
        PaletteItemKind.Schema => "",
        PaletteItemKind.Procedure or PaletteItemKind.Function => "",
        PaletteItemKind.Trigger => "",
        PaletteItemKind.Type => "",
        PaletteItemKind.SavedQuery => "",
        PaletteItemKind.History => "",
        PaletteItemKind.Connection => "",
        PaletteItemKind.Command => "",
        _ => "",
    };
}
