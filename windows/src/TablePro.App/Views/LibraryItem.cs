using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;

namespace TablePro.App.Views;

public sealed partial class TagChip(string name, Brush fill)
{
    public string Name { get; } = name;

    public Brush Fill { get; } = fill;
}

public sealed partial class LibraryItem : INotifyPropertyChanged
{
    private readonly Symbol _symbol;
    private bool _isRenaming;

    internal LibraryItem(LibraryNode node, string title, string detail, Symbol symbol, bool startsExpanded, IReadOnlyList<TagChip> tags)
    {
        Node = node;
        Title = title;
        Detail = detail;
        _symbol = symbol;
        StartsExpanded = startsExpanded;
        Tags = tags;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public LibraryNode Node { get; }

    public string Title { get; }

    public string Detail { get; }

    public bool StartsExpanded { get; }

    public IReadOnlyList<TagChip> Tags { get; }

    public ObservableCollection<LibraryItem> Children { get; } = [];

    // A recycled container binds again and needs an icon of its own.
    public IconElement Glyph => Node.Connection is { } connection
        ? EngineIcons.Mark(connection.EngineId, connection.Color)
        : new SymbolIcon(_symbol);

    public string AccessibleName
    {
        get
        {
            var name = string.IsNullOrEmpty(Detail) ? Title : $"{Title}, {Detail}";
            return Tags.Count == 0 ? name : $"{name}, {string.Join(", ", Tags.Select(tag => tag.Name))}";
        }
    }

    public Style TitleStyle => (Style)Application.Current.Resources[
        Node.Kind is LibraryNodeKind.Favorites or LibraryNodeKind.Recent or LibraryNodeKind.AllConnections
            ? "BodyStrongTextBlockStyle"
            : "BodyTextBlockStyle"];

    public bool CanDrag => Node.Kind is LibraryNodeKind.Connection or LibraryNodeKind.Group;

    // Recent ranks itself, so nothing drops there.
    public bool AllowDrop => Node.Kind != LibraryNodeKind.Recent && Node.Section != LibraryTree.RecentSection;

    public bool CanRename => Node.Kind is LibraryNodeKind.Connection or LibraryNodeKind.Group;

    public bool IsRenaming
    {
        get => _isRenaming;
        set
        {
            if (_isRenaming != value)
            {
                _isRenaming = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(TitleVisibility)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RenameVisibility)));
            }
        }
    }

    public Visibility TitleVisibility => _isRenaming ? Visibility.Collapsed : Visibility.Visible;

    public Visibility RenameVisibility => _isRenaming ? Visibility.Visible : Visibility.Collapsed;

    public Visibility TagsVisibility => Tags.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
}
