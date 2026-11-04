using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

public enum ObjectNodeKind
{
    Schema,
    Folder,
    Item,
    ShowAll,
    FilterHint,
}

// A row of the object tree, or of the list that replaces it while filtering or showing a whole folder.
public sealed partial class ObjectNode : INotifyPropertyChanged
{
    private bool _hasUnrealizedChildren;

    public ObjectNode(ObjectNodeKind kind, string title)
    {
        Kind = kind;
        Title = title;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObjectNodeKind Kind { get; }

    public string Title { get; }

    public string Detail { get; set; } = string.Empty;

    public Symbol Icon { get; set; } = Symbol.Document;

    public string? Schema { get; set; }

    public ObjectEntry? Entry { get; set; }

    public ObjectFolder? Folder { get; set; }

    public ObservableCollection<ObjectNode> Children { get; } = [];

    public bool StartsExpanded { get; set; }

    public string AccessibleName => string.IsNullOrEmpty(Detail) ? Title : $"{Title}, {Detail}";

    public bool HasUnrealizedChildren
    {
        get => _hasUnrealizedChildren;
        set => Set(ref _hasUnrealizedChildren, value);
    }

    private void Set(ref bool field, bool value, [CallerMemberName] string? name = null)
    {
        if (field == value)
        {
            return;
        }

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
