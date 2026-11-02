using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;

namespace TablePro.App.Views;

// A row of the Connections page's tree, over the model's node.
public sealed partial class LibraryItem : INotifyPropertyChanged
{
    private bool _isExpanded;

    public LibraryItem(LibraryNode node, string title, string detail, Symbol icon, bool isExpanded)
    {
        Node = node;
        Title = title;
        Detail = detail;
        Icon = icon;
        _isExpanded = isExpanded;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public LibraryNode Node { get; }

    public string Title { get; }

    public string Detail { get; }

    public Symbol Icon { get; }

    public ObservableCollection<LibraryItem> Children { get; } = [];

    public string AccessibleName => string.IsNullOrEmpty(Detail) ? Title : $"{Title}, {Detail}";

    public Style TitleStyle => (Style)Application.Current.Resources[
        Node.Kind is LibraryNodeKind.Favorites or LibraryNodeKind.Recent or LibraryNodeKind.AllConnections
            ? "BodyStrongTextBlockStyle"
            : "BodyTextBlockStyle"];

    public bool IsExpanded
    {
        get => _isExpanded;
        set
        {
            if (_isExpanded == value)
            {
                return;
            }

            _isExpanded = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsExpanded)));
        }
    }
}
