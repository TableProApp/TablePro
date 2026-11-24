using System.Collections.ObjectModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.Foundation;
using Windows.System;

namespace TablePro.App.Views;

// One connection's runs, newest first; the paging, the search and the deletes are HistoryList's.
public sealed partial class HistoryPane : UserControl
{
    private readonly HistoryList? _list;
    private readonly HistoryItemCollection? _items;

    // Null list: the history store could not open, so nothing is recorded or shown.
    internal HistoryPane(HistoryList? list)
    {
        InitializeComponent();
        _list = list;
        EntriesList.ContainerContentChanging += OnEntryContainerChanging;
        EntriesList.AddHandler(KeyDownEvent, new KeyEventHandler(OnEntriesKeyDown), handledEventsToo: true);
        if (list is null)
        {
            SearchBox.IsEnabled = false;
            ClearHistoryButton.IsEnabled = false;
            ShowFailure(Strings.Get("HistoryUnavailableTitle"), Strings.Get("HistoryUnavailableMessage"));
            return;
        }

        _items = new HistoryItemCollection(list);
        EntriesList.ItemsSource = _items;
        // Runs of every connection name the connection each ran on.
        if (list.ConnectionId is null)
        {
            AutomationProperties.SetName(EntriesList, Strings.Get("HistoryListEvery"));
        }

        list.Changed += (_, _) => ShowList();
    }

    // Open in new tab: the workspace opens a query tab with the run's text.
    public event EventHandler<string>? OpenRequested;

    // Save query...: the workspace asks its name and folder.
    public event EventHandler<string>? SaveRequested;

    public event EventHandler? CloseRequested;

    // Saved queries belong to a saved connection, which a file opened without saving is not.
    public bool CanSaveQuery { get; set; }

    public Task RefreshAsync() => _list?.RefreshAsync() ?? Task.CompletedTask;

    // A pane shown for the first time joins the tree only on the next layout, and an unloaded box takes no focus.
    public void FocusSearch()
    {
        if (SearchBox.IsLoaded)
        {
            SearchBox.Focus(FocusState.Programmatic);
            return;
        }

        void OnLoaded(object sender, RoutedEventArgs e)
        {
            SearchBox.Loaded -= OnLoaded;
            SearchBox.Focus(FocusState.Programmatic);
        }

        SearchBox.Loaded += OnLoaded;
    }

    private void ShowList()
    {
        if (_list is not { } list || _items is not { } items)
        {
            return;
        }

        items.Show(list.Entries, DateTimeOffset.Now);
        ClearHistoryButton.IsEnabled = list.Entries.Count > 0;
        if (list.Failure is { } failure)
        {
            ShowFailure(Strings.Get("HistoryFailedTitle"), Strings.Error(failure));
        }
        else
        {
            FailureBar.IsOpen = false;
            FailureBar.Visibility = Visibility.Collapsed;
        }

        var empty = list.Entries.Count == 0 && !list.IsLoading && list.Failure is null;
        EmptyText.Text = Strings.Get(string.IsNullOrWhiteSpace(list.Text) ? "HistoryEmpty" : "HistoryNoMatches");
        EmptyText.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowFailure(string title, string message)
    {
        // A closed InfoBar keeps its margin, so the bar is collapsed while it is closed.
        FailureBar.Visibility = Visibility.Visible;
        if (FailureBar.IsOpen && FailureBar.Message == message)
        {
            return;
        }

        FailureBar.Title = title;
        FailureBar.Message = message;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        FailureBar.IsOpen = false;
        FailureBar.IsOpen = true;
    }

    private async void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (_list is { } list && args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            await list.SearchAsync(sender.Text).ConfigureAwait(true);
        }
    }

    // Every connection's runs go, as the core's store clears them all, so it asks first; Enter cancels.
    private async void OnClearHistory(object sender, RoutedEventArgs e)
    {
        if (_list is not { } list)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = ActualTheme,
            Title = Strings.Get("ClearHistoryTitle"),
            Content = Strings.Get("ClearHistoryMessage"),
            PrimaryButtonText = Strings.Get("ClearHistoryAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) == ContentDialogResult.Primary)
        {
            await list.ClearAsync().ConfigureAwait(true);
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);

    private void OnEntryDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ContainerAt(e.OriginalSource) is { } container
            && EntriesList.ItemFromContainer(container) is HistoryItem item)
        {
            e.Handled = true;
            OpenRequested?.Invoke(this, item.Entry.Sql);
        }
    }

    private void OnEntriesKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && EntriesList.SelectedItem is HistoryItem item)
        {
            e.Handled = true;
            OpenRequested?.Invoke(this, item.Entry.Sql);
        }
    }

    // Built when asked for, since a menu keeps the window it first opened in and a tab can move to another.
    private void OnEntryContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (_list is not { } list
            || ContainerAt(args.OriginalSource) is not { } container
            || EntriesList.ItemFromContainer(container) is not HistoryItem item)
        {
            return;
        }

        args.Handled = true;
        EntriesList.SelectedItem = item;
        var delete = MenuItem("HistoryMenuDelete", Symbol.Delete);
        delete.Click += async (_, _) => await list.DeleteAsync(item.Entry).ConfigureAwait(true);
        var open = MenuItem("HistoryMenuOpen", Symbol.Add);
        open.Click += (_, _) => OpenRequested?.Invoke(this, item.Entry.Sql);
        var copy = MenuItem("HistoryMenuCopy", Symbol.Copy);
        copy.Click += (_, _) => WorkspaceView.CopyText(item.Entry.Sql);
        var save = MenuItem("HistoryMenuSaveQuery", Symbol.Save);
        save.IsEnabled = CanSaveQuery;
        save.Click += (_, _) => SaveRequested?.Invoke(this, item.Entry.Sql);
        var pinned = item.Entry.Pinned;
        var pin = pinned ? MenuItem("HistoryMenuUnpin", Symbol.UnPin) : MenuItem("HistoryMenuPin", Symbol.Pin);
        pin.Click += async (_, _) => await list.SetPinnedAsync(item.Entry, !pinned).ConfigureAwait(true);
        var menu = new MenuFlyout();
        menu.Items.Add(open);
        menu.Items.Add(copy);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(save);
        menu.Items.Add(pin);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(delete);
        if (args.TryGetPosition(container, out var point))
        {
            menu.ShowAt(container, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt(container);
        }
    }

    private static MenuFlyoutItem MenuItem(string text, Symbol icon)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text), Icon = new SymbolIcon(icon) };
        AutomationProperties.SetAutomationId(item, text);
        return item;
    }

    // The row under the pointer, or the focused row, from whichever element inside it raised the event.
    private static ListViewItem? ContainerAt(object? source)
    {
        var element = source as DependencyObject;
        while (element is not null and not ListViewItem)
        {
            element = VisualTreeHelper.GetParent(element);
        }

        return element as ListViewItem;
    }

    // A list item's name comes from its container, not from the template inside it.
    private static void OnEntryContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is HistoryItem item)
        {
            AutomationProperties.SetName(args.ItemContainer, item.AccessibleName);
        }
    }
}

// The list asks for the next page as its end comes into view; HistoryList reads it from the store.
public sealed partial class HistoryItemCollection : ObservableCollection<HistoryItem>, ISupportIncrementalLoading
{
    private readonly HistoryList _list;

    internal HistoryItemCollection(HistoryList list)
    {
        _list = list;
    }

    // Not while a page is read, since the list then asks again at once; nor after a failure, which the bar shows.
    public bool HasMoreItems => _list.HasMore && !_list.IsLoading && _list.Failure is null;

    public IAsyncOperation<LoadMoreItemsResult> LoadMoreItemsAsync(uint count) => LoadPageAsync().AsAsyncOperation();

    // Runs already shown keep their rows, so a page added at the end leaves the list where it was scrolled.
    internal void Show(IReadOnlyList<HistoryEntry> entries, DateTimeOffset now)
    {
        var kept = 0;
        while (kept < Count
            && kept < entries.Count
            && this[kept].Entry.Id == entries[kept].Id
            && this[kept].Entry.Pinned == entries[kept].Pinned)
        {
            kept++;
        }

        while (Count > kept)
        {
            RemoveAt(Count - 1);
        }

        for (var index = kept; index < entries.Count; index++)
        {
            Add(new HistoryItem(entries[index], now, _list.ConnectionId is null));
        }
    }

    // The pane shows the page as the list raises Changed, before this returns.
    private async Task<LoadMoreItemsResult> LoadPageAsync()
    {
        var before = Count;
        await _list.LoadMoreAsync().ConfigureAwait(true);
        var added = (uint)Math.Max(0, Count - before);
        return new LoadMoreItemsResult { Count = added };
    }
}

public sealed partial class HistoryItem
{
    internal HistoryItem(HistoryEntry entry, DateTimeOffset now, bool namesConnection)
    {
        Entry = entry;
        FirstLine = FirstLineOf(entry.Sql);
        var ran = entry.ExecutedAt.ToLocalTime();
        var time = ran.ToString(ran.Date == now.ToLocalTime().Date ? "t" : "g", CultureInfo.CurrentCulture);
        var detail = entry.Duration is { } duration ? Strings.Format("HistoryDetail", time, DurationText(duration)) : time;
        Detail = namesConnection ? Strings.Format("HistoryDetailConnection", entry.ConnectionName, detail) : detail;
        var (glyph, mark) = entry.Outcome switch
        {
            HistoryOutcome.Failed failed => ("\uE783", Strings.Format("HistoryFailed", failed.Message)),
            HistoryOutcome.Cancelled => ("\uE711", Strings.Get("HistoryCancelled")),
            _ => (string.Empty, string.Empty),
        };
        Glyph = glyph;
        MarkName = mark;
        MarkVisibility = glyph.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        PinName = entry.Pinned ? Strings.Get("HistoryPinned") : string.Empty;
        PinVisibility = entry.Pinned ? Visibility.Visible : Visibility.Collapsed;
        AccessibleName = string.Join(", ", new[] { FirstLine, Detail, MarkName, PinName }.Where(part => part.Length > 0));
    }

    public HistoryEntry Entry { get; }

    public string FirstLine { get; }

    public string Detail { get; }

    public string Glyph { get; }

    public string MarkName { get; }

    public Visibility MarkVisibility { get; }

    public string PinName { get; }

    public Visibility PinVisibility { get; }

    public string AccessibleName { get; }

    private static string FirstLineOf(string sql)
    {
        foreach (var line in sql.AsSpan().EnumerateLines())
        {
            var trimmed = line.Trim();
            if (!trimmed.IsEmpty)
            {
                return trimmed.ToString();
            }
        }

        return string.Empty;
    }

    private static string DurationText(TimeSpan duration) => duration.TotalMilliseconds < 1000
        ? Strings.Format("HistoryDurationMilliseconds", (long)duration.TotalMilliseconds)
        : Strings.Format("HistoryDurationSeconds", duration.TotalSeconds);
}
