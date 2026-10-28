namespace TablePro.Core.Import;

/// <summary>What one field of the file does: skipped, or written to a column. A field can be unticked while still naming a column.</summary>
public readonly record struct ImportFieldChoice(bool Include, string? Column)
{
    public static ImportFieldChoice Skipped { get; } = new(false, null);

    public string? MappedColumn => Include ? Column : null;
}

/// <summary>
/// Matches the fields of a file to the columns of a table, as the macOS import sheet does: exact names before
/// case-insensitive ones, and each column to one field at most, since the import refuses two fields in one column.
/// </summary>
public static class ImportColumnMatcher
{
    public static ImportFieldChoice[] ByName(IReadOnlyList<string> fields, IReadOnlyList<string> columns) => Resolve(fields, columns, []);

    /// <summary>The first field to the first column, and so on; fields past the last column are skipped.</summary>
    public static ImportFieldChoice[] ByPosition(IReadOnlyList<string> fields, IReadOnlyList<string> columns)
    {
        ArgumentNullException.ThrowIfNull(fields);
        ArgumentNullException.ThrowIfNull(columns);
        var choices = new ImportFieldChoice[fields.Count];
        for (var i = 0; i < choices.Length; i++)
        {
            choices[i] = i < columns.Count ? new ImportFieldChoice(true, columns[i]) : ImportFieldChoice.Skipped;
        }

        return choices;
    }

    /// <summary>
    /// Settles each tier of earlier choices for every field before the next tier starts, so a higher tier wins a
    /// column whatever the field order, then matches the rest by exact and then case-insensitive name. A choice that
    /// can no longer be honored, because its column is gone or taken, falls through to the name match.
    /// </summary>
    public static ImportFieldChoice[] Resolve(IReadOnlyList<string> fields, IReadOnlyList<string> columns, IReadOnlyList<IReadOnlyDictionary<string, ImportFieldChoice>> tiers)
    {
        ArgumentNullException.ThrowIfNull(fields);
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentNullException.ThrowIfNull(tiers);
        var claimed = new HashSet<string>(StringComparer.Ordinal);
        var choices = new ImportFieldChoice?[fields.Count];
        foreach (var tier in tiers)
        {
            for (var i = 0; i < fields.Count; i++)
            {
                if (choices[i] is not null || ChoiceFor(fields[i], fields, tier) is not { } preferred)
                {
                    continue;
                }

                if (preferred.Column is not { } wanted)
                {
                    choices[i] = preferred;
                    continue;
                }

                var available = MatchingColumn(wanted, columns, preferred.Include ? claimed : null);
                if (available is null)
                {
                    if (!preferred.Include)
                    {
                        choices[i] = ImportFieldChoice.Skipped;
                    }

                    continue;
                }

                if (preferred.Include)
                {
                    claimed.Add(available);
                }

                choices[i] = new ImportFieldChoice(preferred.Include, available);
            }
        }

        for (var i = 0; i < fields.Count; i++)
        {
            if (choices[i] is null && Contains(columns, fields[i]) && claimed.Add(fields[i]))
            {
                choices[i] = new ImportFieldChoice(true, fields[i]);
            }
        }

        var result = new ImportFieldChoice[fields.Count];
        for (var i = 0; i < fields.Count; i++)
        {
            if (choices[i] is { } settled)
            {
                result[i] = settled;
                continue;
            }

            var column = MatchingColumn(fields[i], columns, claimed);
            if (column is not null)
            {
                claimed.Add(column);
            }

            result[i] = column is null ? ImportFieldChoice.Skipped : new ImportFieldChoice(true, column);
        }

        return result;
    }

    /// <summary>
    /// An earlier choice for a field spelled differently only by case counts when that is unambiguous on both sides:
    /// <c>Email</c> and <c>email</c> can be two fields of one file.
    /// </summary>
    private static ImportFieldChoice? ChoiceFor(string field, IReadOnlyList<string> fields, IReadOnlyDictionary<string, ImportFieldChoice> prior)
    {
        if (prior.TryGetValue(field, out var exact))
        {
            return exact;
        }

        if (fields.Count(f => string.Equals(f, field, StringComparison.OrdinalIgnoreCase)) != 1)
        {
            return null;
        }

        string? variant = null;
        foreach (var key in prior.Keys)
        {
            if (string.Equals(key, field, StringComparison.OrdinalIgnoreCase))
            {
                if (variant is not null)
                {
                    return null;
                }

                variant = key;
            }
        }

        return variant is null ? null : prior[variant];
    }

    private static string? MatchingColumn(string name, IReadOnlyList<string> columns, HashSet<string>? claimed)
    {
        if (Contains(columns, name) && claimed?.Contains(name) != true)
        {
            return name;
        }

        foreach (var column in columns)
        {
            if (claimed?.Contains(column) != true && string.Equals(column, name, StringComparison.OrdinalIgnoreCase))
            {
                return column;
            }
        }

        return null;
    }

    private static bool Contains(IReadOnlyList<string> columns, string name)
    {
        foreach (var column in columns)
        {
            if (string.Equals(column, name, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }
}
