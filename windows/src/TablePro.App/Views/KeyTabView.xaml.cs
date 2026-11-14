using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// One key's value a window at a time; the reads and the close are KeyTab's, so Run does nothing here.
public sealed partial class KeyTabView : UserControl, ITabContent, IKeyTabView
{
    private readonly KeyTab _model;
    private ResultSet? _rows;
    private bool _gridIsTarget;

    internal KeyTabView(SessionShare<DatabaseSession> share, string key)
    {
        InitializeComponent();
        _model = new KeyTab(new CoreTabSession(share), this, key, () => new CoreKeyRead(share.Session.OpenKey(key)));
        _model.StateChanged += (_, _) =>
        {
            UpdateCommands();
            StateChanged?.Invoke(this, EventArgs.Empty);
        };
        Title = key;
        KeyGrid.SizeColumnsToContent = true;
        // The rows arrive a window at a time in the engine's order, which a sort of the rows held would break.
        KeyGrid.SortRequested += (_, _) => KeyGrid.Sort = GridSort.None;
        KeyGrid.GotFocus += (_, _) => _gridIsTarget = true;
        DisplaySettings.Follow(KeyGrid);
    }

    public event EventHandler? StateChanged;

    public string Title { get; }

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

    public SqlEditor? Editor => null;

    public DataGridView? Grid => KeyGrid;

    public bool GridIsTarget => _gridIsTarget && KeyGrid.Visibility == Visibility.Visible;

    public TextBox? MessagesTarget => null;

    public bool Shows(string key) => string.Equals(_model.Key, key, StringComparison.Ordinal);

    public async void Load() => await _model.LoadAsync().ConfigureAwait(true);

    public void Run()
    {
    }

    public void Stop() => _model.Stop();

    public void FocusContent()
    {
        if (KeyGrid.Visibility == Visibility.Visible)
        {
            KeyGrid.Focus(FocusState.Programmatic);
        }
        else
        {
            RefreshButton.Focus(FocusState.Programmatic);
        }
    }

    public SessionTab Snapshot() => _model.Snapshot();

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

    void IKeyTabView.ShowReading()
    {
        ShowBar(ErrorBar, false);
        StatusText.Text = Strings.Get("KeyStatusReading");
        // What the last read found stays on screen until this one lands.
        LoadingRing.IsActive =
            Header.Visibility == Visibility.Collapsed && MissingPanel.Visibility == Visibility.Collapsed;
        UpdateCommands();
    }

    void IKeyTabView.ShowRows(ResultSet? rows)
    {
        _rows = rows;
        KeyGrid.SetData(rows is null ? null : new ResultSetData(rows, rows.GetColumns()));
    }

    void IKeyTabView.ShowWindow(KeyWindow window)
    {
        var other = window.Kind == KeyKind.Other;
        LoadingRing.IsActive = false;
        MissingPanel.Visibility = Visibility.Collapsed;
        Header.Visibility = Visibility.Visible;
        TypeText.Text = other ? window.TypeName : Strings.Get("KeyType_" + window.Kind);
        LengthText.Text = window.Length is { } length ? LengthWords(window.Kind, length) : string.Empty;
        LengthText.Visibility = window.Length is null ? Visibility.Collapsed : Visibility.Visible;
        TtlText.Text = TtlWords(window.Ttl);
        OtherText.Text = other ? Strings.Format("KeyOtherMessage", window.TypeName) : string.Empty;
        OtherPanel.Visibility = other ? Visibility.Visible : Visibility.Collapsed;
        KeyGrid.Visibility = other ? Visibility.Collapsed : Visibility.Visible;
        KeyGrid.RowsChanged();
        ShowCut(window);
        StatusText.Text = window.Kind is KeyKind.Text or KeyKind.Other ? string.Empty : ShownWords(window);
        UpdateCommands();
    }

    void IKeyTabView.ReleaseRows()
    {
        KeyGrid.SetData(null);
        _rows = null;
    }

    void IKeyTabView.ShowMissing()
    {
        LoadingRing.IsActive = false;
        Header.Visibility = Visibility.Collapsed;
        KeyGrid.Visibility = Visibility.Collapsed;
        OtherPanel.Visibility = Visibility.Collapsed;
        ShowBar(CutBar, false);
        MissingPanel.Visibility = Visibility.Visible;
        StatusText.Text = Strings.Get("KeyStatusMissing");
        UpdateCommands();
    }

    void IKeyTabView.ShowFailure(CoreError failure)
    {
        LoadingRing.IsActive = false;
        ErrorBar.Message = Strings.Error(failure);
        // Opened again, so a second failure in a row is announced as well.
        ShowBar(ErrorBar, false);
        ShowBar(ErrorBar, true);
        StatusText.Text = Strings.Get("KeyStatusFailed");
        UpdateCommands();
    }

    void IKeyTabView.ShowStopped()
    {
        LoadingRing.IsActive = false;
        StatusText.Text = Strings.Get("KeyStatusStopped");
        UpdateCommands();
    }

    private static string LengthWords(KeyKind kind, long length)
    {
        var unit = kind switch
        {
            KeyKind.Text => "Bytes",
            KeyKind.Hash => "Fields",
            KeyKind.List => "Elements",
            KeyKind.Set or KeyKind.SortedSet => "Members",
            _ => "Entries",
        };
        return length == 1
            ? Strings.Get("KeyLength" + unit + "One")
            : Strings.Format("KeyLength" + unit + "Many", length);
    }

    private static string TtlWords(KeyTtl ttl)
    {
        if (ttl is not KeyTtl.ExpiresIn { Left: var left })
        {
            return Strings.Get(ttl is KeyTtl.Persistent ? "KeyTtlNone" : "KeyTtlUnknown");
        }

        // A key with under a second left has not expired, so it reads as one second rather than none.
        var seconds = Math.Max(1, (long)left.TotalSeconds);
        return seconds switch
        {
            < 60 => Strings.Format("KeyTtlSeconds", seconds),
            < 3_600 => TwoUnits("KeyTtlMinutes", seconds / 60, seconds % 60),
            < 86_400 => TwoUnits("KeyTtlHours", seconds / 3_600, (seconds % 3_600) / 60),
            _ => TwoUnits("KeyTtlDays", seconds / 86_400, (seconds % 86_400) / 3_600),
        };
    }

    private static string TwoUnits(string name, long whole, long part) =>
        part == 0 ? Strings.Format(name, whole) : Strings.Format(name + "And", whole, part);

    private static string ShownWords(KeyWindow window) =>
        window.Length is { } length && length > window.Rows
            ? Strings.Format("KeyStatusShownOf", window.Rows, length)
            : Strings.Format("KeyStatusShown", window.Rows);

    // A string longer than one window: its row holds the start, cut where a character ends.
    private void ShowCut(KeyWindow window)
    {
        string? message = null;
        if (window is { Kind: KeyKind.Text, Truncated: true, Length: { } total } && _rows is { RowCount: > 0 } rows)
        {
            message = Strings.Format("KeyCut", ByteCount(rows.GetCellText(0, 0) ?? string.Empty), total);
        }

        CutBar.Message = message ?? string.Empty;
        ShowBar(CutBar, message is not null);
    }

    // A value that is not UTF-8 reads as 0x and its bytes in hex.
    private static long ByteCount(string text) =>
        text.StartsWith("0x", StringComparison.Ordinal) && text.Length % 2 == 0 && IsHex(text.AsSpan(2))
            ? (text.Length - 2) / 2
            : Encoding.UTF8.GetByteCount(text);

    private static bool IsHex(ReadOnlySpan<char> digits)
    {
        foreach (var digit in digits)
        {
            if (!char.IsAsciiHexDigitLower(digit))
            {
                return false;
            }
        }

        return true;
    }

    // A closed InfoBar keeps its margin, so a bar is collapsed while it is closed.
    private static void ShowBar(InfoBar bar, bool show)
    {
        bar.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        bar.IsOpen = show;
    }

    private void UpdateCommands()
    {
        RefreshButton.IsEnabled = !_model.IsRunning;
        LoadMoreButton.Visibility = _model.Window is { HasMore: true } ? Visibility.Visible : Visibility.Collapsed;
        LoadMoreButton.IsEnabled = _model.CanLoadMore;
    }

    private void OnErrorBarClosed(InfoBar sender, InfoBarClosedEventArgs args) =>
        ErrorBar.Visibility = Visibility.Collapsed;

    private async void OnLoadMore(object sender, RoutedEventArgs e) =>
        await _model.LoadMoreAsync().ConfigureAwait(true);

    private async void OnRefresh(object sender, RoutedEventArgs e) => await _model.LoadAsync().ConfigureAwait(true);
}
