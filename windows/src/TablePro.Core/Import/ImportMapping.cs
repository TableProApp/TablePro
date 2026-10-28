using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Core.Import;

/// <summary>A column of the table an import writes to, with the type its values are parsed into.</summary>
public sealed record ImportTargetColumn(string Name, string DataType, Type ClrType);

public enum ImportDestination
{
    ExistingTable,
    NewTable,
}

/// <summary>
/// The fields of a file against the columns of an existing table, as the macOS import sheet edits them. Every field
/// starts matched by name; the user picks another column or skips it.
/// </summary>
public sealed class ImportMapping
{
    private ImportFieldChoice[] _choices;

    public ImportMapping(IReadOnlyList<ImportField> fields, IReadOnlyList<ImportTargetColumn> columns)
    {
        ArgumentNullException.ThrowIfNull(fields);
        ArgumentNullException.ThrowIfNull(columns);
        Fields = fields;
        Columns = columns;
        ColumnNames = [.. columns.Select(c => c.Name)];
        _choices = ImportColumnMatcher.ByName(FieldNames, ColumnNames);
    }

    public IReadOnlyList<ImportField> Fields { get; private set; }

    public IReadOnlyList<ImportTargetColumn> Columns { get; }

    public IReadOnlyList<string> ColumnNames { get; }

    public IReadOnlyList<ImportFieldChoice> Choices => _choices;

    private string[] FieldNames => [.. Fields.Select(f => f.Name)];

    public ImportFieldChoice this[int field]
    {
        get => _choices[field];
        set => _choices[field] = value;
    }

    /// <summary>The column a field goes to, by field name, for every included field with a column.</summary>
    public IReadOnlyDictionary<string, string> ColumnMapping
    {
        get
        {
            var mapping = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var i = 0; i < _choices.Length; i++)
            {
                if (_choices[i].MappedColumn is { } column)
                {
                    mapping[Fields[i].Name] = column;
                }
            }

            return mapping;
        }
    }

    public bool HasMappedField => _choices.Any(c => c.MappedColumn is not null);

    public bool MapsOneColumnTwice
    {
        get
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var choice in _choices)
            {
                if (choice.MappedColumn is { } column && !seen.Add(column))
                {
                    return true;
                }
            }

            return false;
        }
    }

    /// <summary>Why the import cannot run yet, in the words the dialog shows, or null when it can.</summary>
    public string? Problem =>
        !HasMappedField ? "Map at least one field to a column." : MapsOneColumnTwice ? "Each column can be mapped from only one field." : null;

    public ImportTargetColumn? ColumnFor(string? name) =>
        name is null ? null : Columns.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase));

    public void MatchByName() => _choices = ImportColumnMatcher.ByName(FieldNames, ColumnNames);

    public void MatchByPosition() => _choices = ImportColumnMatcher.ByPosition(FieldNames, ColumnNames);

    public void SetAllIncluded(bool include)
    {
        for (var i = 0; i < _choices.Length; i++)
        {
            _choices[i] = _choices[i] with { Include = include };
        }
    }

    /// <summary>
    /// Takes the fields of a new read of the file, after a parsing option changed. The choices made so far are kept
    /// for the fields that are still there, ahead of the name match.
    /// </summary>
    public void Reload(IReadOnlyList<ImportField> fields)
    {
        ArgumentNullException.ThrowIfNull(fields);
        var session = new Dictionary<string, ImportFieldChoice>(StringComparer.Ordinal);
        for (var i = 0; i < _choices.Length; i++)
        {
            session.TryAdd(Fields[i].Name, _choices[i]);
        }

        Fields = fields;
        _choices = ImportColumnMatcher.Resolve(FieldNames, ColumnNames, [session]);
    }

    /// <summary>Parses each mapped value into its column's type.</summary>
    public ImportRowBuilder CreateRowBuilder()
    {
        var types = new Dictionary<string, Type>(StringComparer.OrdinalIgnoreCase);
        foreach (var column in Columns)
        {
            types.TryAdd(column.Name, column.ClrType);
        }

        return new ImportRowBuilder(ColumnMapping, types);
    }
}

/// <summary>What the import makes of one field in the table it creates.</summary>
public sealed record NewTableColumnSettings(bool Include, string Name, string Type, bool IsPrimaryKey, bool IsNullable, string DefaultValue)
{
    /// <summary>Every field under its own name, with the type its values suggest, nullable, with no key and no default.</summary>
    public static NewTableColumnSettings Proposed(string name, string type) => new(true, name, type, false, true, string.Empty);
}

/// <summary>
/// What the user changed on one column, each setting null until changed. A new read of the file proposes again, and a
/// setting left alone follows it while a changed one stays the user's.
/// </summary>
public sealed record NewTableColumnEdits(bool? Include = null, string? Name = null, string? Type = null, bool? IsPrimaryKey = null, bool? IsNullable = null, string? DefaultValue = null)
{
    public bool IsEmpty => this == new NewTableColumnEdits();

    public NewTableColumnSettings AppliedTo(NewTableColumnSettings proposal) => new(
        Include ?? proposal.Include,
        Name ?? proposal.Name,
        Type ?? proposal.Type,
        IsPrimaryKey ?? proposal.IsPrimaryKey,
        IsNullable ?? proposal.IsNullable,
        DefaultValue ?? proposal.DefaultValue);

    /// <summary>A type differing only in case is not a change: choosing the shown type again writes the dialect's own spelling back.</summary>
    public NewTableColumnEdits Recording(NewTableColumnSettings settings, NewTableColumnSettings shown) => new(
        settings.Include == shown.Include ? Include : settings.Include,
        settings.Name == shown.Name ? Name : settings.Name,
        string.Equals(settings.Type, shown.Type, StringComparison.OrdinalIgnoreCase) ? Type : settings.Type,
        settings.IsPrimaryKey == shown.IsPrimaryKey ? IsPrimaryKey : settings.IsPrimaryKey,
        settings.IsNullable == shown.IsNullable ? IsNullable : settings.IsNullable,
        settings.DefaultValue == shown.DefaultValue ? DefaultValue : settings.DefaultValue);
}

/// <summary>One field of the file and the column the user is making of it.</summary>
public sealed class NewTableColumn(ImportField field, NewTableColumnSettings proposal, NewTableColumnEdits? edits = null)
{
    public ImportField Field { get; } = field;

    public NewTableColumnSettings Proposal { get; } = proposal;

    public NewTableColumnEdits Edits { get; private set; } = edits ?? new NewTableColumnEdits();

    public NewTableColumnSettings Settings
    {
        get => Edits.AppliedTo(Proposal);
        set => Edits = Edits.Recording(value, Settings);
    }
}

/// <summary>
/// The table an import creates: the fields of the file, what was proposed for each, and what the user changed. Edits
/// survive a re-read of the file, so correcting the delimiter does not throw away renames and types.
/// </summary>
public sealed class NewTableDraft
{
    private readonly Dictionary<string, NewTableColumnEdits> _setAside = new(StringComparer.Ordinal);
    private List<NewTableColumn> _columns = [];

    public IReadOnlyList<NewTableColumn> Columns => _columns;

    public void Load(IReadOnlyList<ImportField> fields, Func<ImportFieldType, string> proposeType)
    {
        ArgumentNullException.ThrowIfNull(fields);
        ArgumentNullException.ThrowIfNull(proposeType);
        foreach (var column in _columns)
        {
            _setAside[column.Field.Name] = column.Edits;
        }

        _columns = [.. fields.Select(field =>
        {
            _setAside.Remove(field.Name, out var edits);
            return new NewTableColumn(field, NewTableColumnSettings.Proposed(field.Name, proposeType(field.InferredType)), edits);
        })];

        // A wrong delimiter reads other fields for one read; correcting it brings their edits back.
        foreach (var key in _setAside.Where(e => e.Value.IsEmpty).Select(e => e.Key).ToArray())
        {
            _setAside.Remove(key);
        }
    }

    public bool IncludesEveryColumn => _columns.Count > 0 && _columns.All(c => c.Settings.Include);

    public void SetAllIncluded(bool include)
    {
        foreach (var column in _columns)
        {
            column.Settings = column.Settings with { Include = include };
        }
    }

    private IEnumerable<NewTableColumn> NamedColumns => _columns.Where(c => c.Settings.Include && !string.IsNullOrWhiteSpace(c.Settings.Name));

    /// <summary>The column each field is written to, for every included field whose column has a name.</summary>
    public IReadOnlyDictionary<string, string> ColumnMapping => NamedColumns.ToDictionary(c => c.Field.Name, c => c.Settings.Name.Trim(), StringComparer.Ordinal);

    public string? Problem
    {
        get
        {
            var names = _columns.Where(c => c.Settings.Include).Select(c => c.Settings.Name.Trim()).ToArray();
            if (names.Length == 0 || names.All(n => n.Length == 0))
            {
                return "Include at least one column.";
            }

            if (names.Any(n => n.Length == 0))
            {
                return "Every included column needs a name.";
            }

            if (_columns.Any(c => c.Settings.Include && string.IsNullOrWhiteSpace(c.Settings.Type)))
            {
                return "Every included column needs a type.";
            }

            return names.Distinct(StringComparer.OrdinalIgnoreCase).Count() == names.Length ? null : "Column names must be unique.";
        }
    }

    /// <summary>The columns of the CREATE TABLE, in file order. A default is SQL, written after DEFAULT as typed.</summary>
    public IReadOnlyList<ColumnDefinition> Definition() =>
    [
        .. NamedColumns.Select(c => c.Settings).Where(s => !string.IsNullOrWhiteSpace(s.Type)).Select(s => new ColumnDefinition(
            s.Name.Trim(),
            s.Type.Trim(),
            IsNullable: s.IsNullable && !s.IsPrimaryKey,
            DefaultExpression: string.IsNullOrWhiteSpace(s.DefaultValue) ? null : s.DefaultValue.Trim(),
            IsPrimaryKey: s.IsPrimaryKey)),
    ];

    /// <summary>Parses each value into the CLR type its proposed field type implies.</summary>
    public ImportRowBuilder CreateRowBuilder()
    {
        var types = new Dictionary<string, Type>(StringComparer.OrdinalIgnoreCase);
        foreach (var column in NamedColumns)
        {
            types.TryAdd(column.Settings.Name.Trim(), ImportTypeMapper.ClrType(column.Field.InferredType));
        }

        return new ImportRowBuilder(ColumnMapping, types);
    }
}

/// <summary>Turns one record of the file into the values of one inserted row.</summary>
public sealed class ImportRowBuilder(IReadOnlyDictionary<string, string> mapping, IReadOnlyDictionary<string, Type> columnTypes)
{
    public IReadOnlyDictionary<string, string> Mapping { get; } = mapping;

    /// <summary>
    /// Text from a CSV, or a JSON string, is parsed for its column's type, and kept as text when it does not parse so
    /// the server's own conversion and error decide. JSON numbers and booleans pass through; nested JSON binds as text.
    /// </summary>
    public Dictionary<string, object?> Build(IReadOnlyDictionary<string, object?> record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var values = new Dictionary<string, object?>(Mapping.Count, StringComparer.OrdinalIgnoreCase);
        foreach (var (field, column) in Mapping)
        {
            if (!record.TryGetValue(field, out var raw))
            {
                // A JSON object without the key leaves the column to its default rather than writing null.
                continue;
            }

            values[column] = raw switch
            {
                JsonText json => json.Text,
                string text when columnTypes.TryGetValue(column, out var type) && ValueParser.TryParse(text, type, out var parsed) => parsed,
                _ => raw,
            };
        }

        return values;
    }
}

/// <summary>The column type a new table proposes for a field, per engine, as the macOS import type mapper does.</summary>
public static class ImportTypeMapper
{
    public static string SqlType(ImportFieldType type, DatabaseEngine engine, string? serverVersion = null) => engine switch
    {
        DatabaseEngine.PostgreSql or DatabaseEngine.Redshift or DatabaseEngine.CockroachDb or DatabaseEngine.PGlite => type switch
        {
            ImportFieldType.Integer => "BIGINT",
            ImportFieldType.Real => "DOUBLE PRECISION",
            ImportFieldType.Boolean => "BOOLEAN",

            // Redshift has no JSON type and keeps semi-structured data in SUPER.
            ImportFieldType.Json => engine == DatabaseEngine.Redshift ? "SUPER" : "JSONB",
            _ => "TEXT",
        },
        DatabaseEngine.MySql or DatabaseEngine.MariaDb or DatabaseEngine.TiDb or DatabaseEngine.OceanBase => type switch
        {
            ImportFieldType.Integer => "BIGINT",
            ImportFieldType.Real => "DOUBLE",
            ImportFieldType.Boolean => "TINYINT(1)",
            ImportFieldType.Json => "JSON",
            _ => "TEXT",
        },
        DatabaseEngine.Sqlite or DatabaseEngine.LibSql or DatabaseEngine.Turso or DatabaseEngine.CloudflareD1 => type switch
        {
            ImportFieldType.Integer or ImportFieldType.Boolean => "INTEGER",
            ImportFieldType.Real => "REAL",
            _ => "TEXT",
        },
        DatabaseEngine.SqlServer => type switch
        {
            ImportFieldType.Integer => "BIGINT",
            ImportFieldType.Real => "FLOAT",
            ImportFieldType.Boolean => "BIT",
            _ => "NVARCHAR(MAX)",
        },

        // Oracle has no TEXT and BOOLEAN only from 23ai; text gets the widest VARCHAR2 since a CLOB cannot be compared.
        DatabaseEngine.Oracle => type switch
        {
            ImportFieldType.Integer => "NUMBER(19)",
            ImportFieldType.Real => "BINARY_DOUBLE",
            ImportFieldType.Boolean => (OracleMajorRelease(serverVersion) ?? 0) >= 23 ? "BOOLEAN" : "VARCHAR2(5 CHAR)",
            ImportFieldType.Json => "CLOB",
            _ => "VARCHAR2(4000 CHAR)",
        },
        DatabaseEngine.DuckDb => type switch
        {
            ImportFieldType.Integer => "BIGINT",
            ImportFieldType.Real => "DOUBLE",
            ImportFieldType.Boolean => "BOOLEAN",
            ImportFieldType.Json => "JSON",
            _ => "VARCHAR",
        },
        _ => type switch
        {
            ImportFieldType.Integer => "INTEGER",
            ImportFieldType.Real => "DOUBLE PRECISION",
            ImportFieldType.Boolean => "BOOLEAN",
            _ => "TEXT",
        },
    };

    public static Type ClrType(ImportFieldType type) => type switch
    {
        ImportFieldType.Integer => typeof(long),
        ImportFieldType.Real => typeof(double),
        ImportFieldType.Boolean => typeof(bool),
        _ => typeof(string),
    };

    /// <summary>The release in an Oracle banner such as <c>Oracle Database 19c Enterprise Edition Release 19.0.0.0.0</c>.</summary>
    public static int? OracleMajorRelease(string? banner)
    {
        if (banner is null)
        {
            return null;
        }

        var at = banner.IndexOf("Release ", StringComparison.OrdinalIgnoreCase);
        if (at < 0)
        {
            return null;
        }

        var digits = banner.AsSpan(at + "Release ".Length).TrimStart();
        var length = 0;
        while (length < digits.Length && char.IsAsciiDigit(digits[length]))
        {
            length++;
        }

        return length > 0 && int.TryParse(digits[..length], System.Globalization.CultureInfo.InvariantCulture, out var release) ? release : null;
    }
}
