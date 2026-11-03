using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.ConnectionForm;

public sealed partial class EngineChoice(DatabaseEngine engine, string detail)
{
    public DatabaseEngine Engine { get; } = engine;

    public string Name => Engine.DisplayName;

    public string Detail { get; } = detail;

    // A recycled container binds again and gets an icon of its own.
    public IconElement Icon => EngineIcons.Glyph(Engine.Id);

    public string AccessibleName => $"{Name}, {Detail}";
}

// CollectionViewSource reads Items by name, which a trimmed AOT app keeps only through this attribute.
[WinRT.GeneratedBindableCustomProperty]
public sealed partial class EngineGroup(string title, IList<EngineChoice> items)
{
    public string Title { get; } = title;

    public IList<EngineChoice> Items { get; } = items;
}
