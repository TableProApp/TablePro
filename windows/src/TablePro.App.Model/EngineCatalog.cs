using TablePro.Interop;

namespace TablePro.App.Model;

public sealed record EngineSection(EngineCategory Category, IReadOnlyList<DatabaseEngine> Engines);

// The connection form's engine chooser: the engines whose names hold the search, by family in the core's order, as
// the macOS app lists them, and by name inside each.
public static class EngineCatalog
{
    public static IReadOnlyList<EngineSection> Sections(IEnumerable<DatabaseEngine> engines, string? query)
    {
        ArgumentNullException.ThrowIfNull(engines);
        var text = query?.Trim() ?? string.Empty;
        return
        [
            .. engines
                .Where(engine => engine.DisplayName.Contains(text, StringComparison.CurrentCultureIgnoreCase))
                .GroupBy(engine => engine.Category)
                .OrderBy(group => group.Key)
                .Select(group => new EngineSection(
                    group.Key,
                    [.. group.OrderBy(engine => engine.DisplayName, StringComparer.CurrentCulture)])),
        ];
    }
}
