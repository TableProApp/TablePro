namespace TablePro.Core.Schema;

/// <summary>
/// The list an editable picker offers and the entry it opens on, such as the column type in the column editor. The
/// current value is always one of the entries, selected, because WinUI's editable ComboBox drops text set from code
/// that matches none of its items when it loads, which opened Edit Column on an empty type for VARCHAR(20).
/// </summary>
public static class EditableChoices
{
    /// <param name="suggestions">What the picker offers, in order.</param>
    /// <param name="current">The value being edited, or null for a new one.</param>
    /// <param name="fallback">What a new value starts as when there are no suggestions.</param>
    public static (IReadOnlyList<string> Items, int SelectedIndex) Build(IReadOnlyList<string> suggestions, string? current, string? fallback = null)
    {
        ArgumentNullException.ThrowIfNull(suggestions);
        var items = suggestions.Where(s => !string.IsNullOrWhiteSpace(s)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var value = string.IsNullOrWhiteSpace(current) ? null : current.Trim();
        if (value is null)
        {
            if (items.Count > 0)
            {
                return (items, 0);
            }

            return string.IsNullOrWhiteSpace(fallback) ? (items, -1) : ([fallback], 0);
        }

        // The type exactly as the database reports it, so saving unchanged alters nothing, even when a suggestion
        // differs only in case.
        var match = items.FindIndex(s => string.Equals(s, value, StringComparison.Ordinal));
        if (match >= 0)
        {
            return (items, match);
        }

        items.Insert(0, value);
        return (items, 0);
    }
}
