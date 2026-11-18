namespace TablePro.Editor.Model;

// Colors are 0xAARRGGBB. The macOS theme's function, type and NULL colors have no token of their own in the core's lexer.
public sealed record ColorScheme(
    string Id,
    string Name,
    bool IsDark,
    uint Background,
    uint Text,
    uint Cursor,
    uint Selection,
    uint CurrentLine,
    uint CurrentStatement,
    uint LineNumber,
    uint Keyword,
    uint StringLiteral,
    uint Number,
    uint Comment,
    uint Operator);

public static partial class ColorSchemes
{
    // Null, or an id no scheme has, keeps the default colors.
    public static ColorScheme? Find(string? id) =>
        string.IsNullOrEmpty(id) ? null : All.FirstOrDefault(scheme => string.Equals(scheme.Id, id, StringComparison.Ordinal));
}
