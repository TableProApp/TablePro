using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;

namespace TablePro.App.Views;

// A row of the Connections page's tree, over the model's node.
public sealed partial class LibraryItem(LibraryNode node, string title, string detail, Symbol icon, bool startsExpanded)
{
    public LibraryNode Node { get; } = node;

    public string Title { get; } = title;

    public string Detail { get; } = detail;

    public Symbol Icon { get; } = icon;

    public bool StartsExpanded { get; } = startsExpanded;

    public ObservableCollection<LibraryItem> Children { get; } = [];

    public string AccessibleName => string.IsNullOrEmpty(Detail) ? Title : $"{Title}, {Detail}";

    public Style TitleStyle => (Style)Application.Current.Resources[
        Node.Kind is LibraryNodeKind.Favorites or LibraryNodeKind.Recent or LibraryNodeKind.AllConnections
            ? "BodyStrongTextBlockStyle"
            : "BodyTextBlockStyle"];
}
