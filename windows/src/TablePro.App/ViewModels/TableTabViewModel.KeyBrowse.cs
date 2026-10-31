using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.Core.Browse;
using TablePro.Core.Drivers;

namespace TablePro.App.ViewModels;

/// <summary>
/// The key pattern and type a key-value database's key listing is searched by, the macOS key pattern bar. They are
/// filter rules like the strip's, kept apart so the strip stays for the other columns.
/// </summary>
public sealed partial class TableTabViewModel
{
    /// <summary>How this table lists keys, or null when it is not a key listing.</summary>
    public KeyBrowseInfo? KeyBrowse => _context.Session.Database is IKeyBrowseProvider keys ? keys.GetKeyBrowse(Table.Name) : null;

    /// <summary>A glob such as <c>user:*</c>, matched on the server.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasKeySearch))]
    public partial string? KeyPattern { get; set; }

    /// <summary>The key type the listing is narrowed to, by the engine's own name; null lists every type.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasKeySearch))]
    public partial string? KeyType { get; set; }

    public bool HasKeySearch => !string.IsNullOrWhiteSpace(KeyPattern) || KeyType is not null;

    /// <summary>Lists the keys a pattern matches, as a namespace picked in the sidebar does.</summary>
    public async Task BrowseKeyPatternAsync(string pattern)
    {
        KeyPattern = pattern;
        Offset = 0;

        // A tab that has not loaded yet reads the pattern on its first load.
        if (Rows is not null)
        {
            await LoadAsync();
        }
    }

    [RelayCommand]
    private async Task ApplyKeySearchAsync()
    {
        Offset = 0;
        await LoadAsync();
    }

    [RelayCommand]
    private async Task ClearKeySearchAsync()
    {
        KeyPattern = null;
        KeyType = null;
        Offset = 0;
        await LoadAsync();
    }

    private IReadOnlyList<FilterRule> KeySearchRules() => KeyBrowse?.Rules(KeyPattern, KeyType) ?? [];
}
