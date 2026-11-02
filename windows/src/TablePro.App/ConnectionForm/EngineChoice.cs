using Microsoft.UI.Xaml.Controls;
using TablePro.Interop;

namespace TablePro.App.ConnectionForm;

public sealed partial class EngineChoice(DatabaseEngine engine, string detail)
{
    public DatabaseEngine Engine { get; } = engine;

    public string Name => Engine.DisplayName;

    public string Detail { get; } = detail;

    public Symbol Icon => Engine.DefaultPort is null ? Symbol.Document : Symbol.Library;

    public string AccessibleName => $"{Name}, {Detail}";
}

// The chooser's GridView groups through a CollectionViewSource, which reads Items by name; the attribute gives that
// lookup to a trimmed, AOT-compiled app.
[WinRT.GeneratedBindableCustomProperty]
public sealed partial class EngineGroup(string title, IList<EngineChoice> items)
{
    public string Title { get; } = title;

    public IList<EngineChoice> Items { get; } = items;
}
