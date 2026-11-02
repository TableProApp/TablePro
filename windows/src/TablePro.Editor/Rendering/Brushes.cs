using TerraFX.Interop.DirectX;
using Windows.UI;

namespace TablePro.Editor.Rendering;

// The palette as Direct2D brushes on one device context. Rebuilt when the theme or the device changes.
internal sealed unsafe class Brushes : IStyleBrushes, IDisposable
{
    private const byte KeywordKind = 1;

    private readonly List<nint> _owned = [];
    private readonly ID2D1Brush*[] _syntax;

    public Brushes(ID2D1DeviceContext* context, Palette palette)
    {
        Palette = palette;
        Text = Create(context, palette.Text);
        LineNumber = Create(context, palette.LineNumber);
        CurrentLine = Create(context, palette.CurrentLine);
        Selection = Create(context, palette.Selection);
        SelectionText = palette.SelectionText is Color selected ? Create(context, selected) : null;
        Caret = Create(context, palette.Caret);
        FindMatch = Create(context, palette.FindMatch);
        _syntax = new ID2D1Brush*[palette.Syntax.Length];
        for (var i = 0; i < palette.Syntax.Length; i++)
        {
            _syntax[i] = palette.Syntax[i] is Color color ? Create(context, color) : null;
        }
    }

    public Palette Palette { get; }

    public ID2D1Brush* Text { get; }

    public ID2D1Brush* LineNumber { get; }

    public ID2D1Brush* CurrentLine { get; }

    public ID2D1Brush* Selection { get; }

    public ID2D1Brush* SelectionText { get; }

    public ID2D1Brush* Caret { get; }

    public ID2D1Brush* FindMatch { get; }

    // Kinds past the syntax table are the editor's own: SelectedText marks high-contrast selected text.
    public const byte SelectedText = 200;

    public ID2D1Brush* For(byte kind)
    {
        if (kind == SelectedText)
        {
            return SelectionText;
        }
        return kind < _syntax.Length ? _syntax[kind] : null;
    }

    public bool IsBold(byte kind) => kind == KeywordKind && !Palette.HighContrast;

    public void Dispose()
    {
        foreach (var brush in _owned)
        {
            ((ID2D1Brush*)brush)->Release();
        }
        _owned.Clear();
    }

    private ID2D1Brush* Create(ID2D1DeviceContext* context, Color color)
    {
        var value = Palette.ToD2D(color);
        ID2D1SolidColorBrush* brush;
        NativeCom.Check(context->CreateSolidColorBrush(&value, null, &brush));
        _owned.Add((nint)brush);
        return (ID2D1Brush*)brush;
    }
}
