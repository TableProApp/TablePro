using CommunityToolkit.Mvvm.ComponentModel;

namespace TablePro.App.ViewModels;

/// <summary>A tab in a workspace window: a query editor, a table, the server dashboard or a diagram.</summary>
public abstract partial class TabViewModel : ObservableObject, IAsyncDisposable
{
    [ObservableProperty]
    public partial string Title { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string? Subtitle { get; set; }

    [ObservableProperty]
    public partial bool IsBusy { get; set; }

    [ObservableProperty]
    public partial string? StatusText { get; set; }

    public abstract string Glyph { get; }

    /// <summary>What closing would lose, or null when the tab can close without asking.</summary>
    public virtual string? UnsavedWork => null;

    public virtual ValueTask DisposeAsync()
    {
        GC.SuppressFinalize(this);
        return ValueTask.CompletedTask;
    }
}
