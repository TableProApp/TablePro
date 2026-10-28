using System.Globalization;

namespace TablePro.Core.Generation;

/// <summary>Why the generator could not make another row.</summary>
public sealed class RowGenerationException(string message) : InvalidOperationException(message)
{
    public static RowGenerationException Exhausted(IEnumerable<string> columns) =>
        new($"Could not make another value for ({string.Join(", ", columns)}) that does not repeat. Widen its range or generate fewer rows.");
}

/// <summary>
/// Makes the rows one at a time, in order, from the settings and the seed alone: the same input gives the same rows.
/// It remembers what it has made for unique columns and keys, so one engine serves one run and is not shared between
/// threads. Values are typed (long, decimal, double, bool, <see cref="DateOnly"/>, <see cref="DateTime"/>,
/// <see cref="TimeOnly"/>, <see cref="Guid"/>, string); the writer converts each to the column's provider type.
/// </summary>
public sealed class RowGenerationEngine
{
    private const int RandomAttempts = 32;
    private const int GroupAttempts = 64;

    // Past this many values a key is not walked one by one: the preview runs on the UI thread.
    private const long WalkLimit = 5_000_000;

    // Version 7 timestamps count up from 2025-01-01 by the row, so the values sort in insert order.
    private const long UuidEpochMilliseconds = 1_735_689_600_000;

    private readonly ColumnState[] _columns;
    private readonly Dictionary<string, SourceState> _sources = new(StringComparer.Ordinal);
    private readonly List<string> _sourceOrder = [];
    private readonly int[][] _groups;
    private readonly HashSet<RowFingerprint>[] _groupSeen;
    private readonly SeededRandom[] _groupRandoms;
    private readonly bool _nullsAreDistinct;
    private long _ordinal;

    /// <param name="table">The table the rows are for.</param>
    /// <param name="settings">Each column's generator, the row count and the seed.</param>
    /// <param name="nullsAreDistinct">False where a unique key counts two NULLs as equal, as SQL Server's does.</param>
    public RowGenerationEngine(RowGenerationTable table, RowGenerationSettings settings, bool nullsAreDistinct = true)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentNullException.ThrowIfNull(settings);
        _nullsAreDistinct = nullsAreDistinct;
        var written = new List<ColumnState>(table.Columns.Count);
        foreach (var column in table.Columns)
        {
            if (settings.Columns.TryGetValue(column.Name, out var columnSettings) && columnSettings.Kind != RowGeneratorKind.ServerDefault)
            {
                written.Add(new ColumnState(column, columnSettings, settings.Seed, table));
            }
        }

        _columns = [.. written];
        ColumnNames = [.. written.Select(c => c.Column.Name)];

        for (var index = 0; index < _columns.Length; index++)
        {
            var state = _columns[index];
            if (state.Settings.Kind != RowGeneratorKind.Reference || state.Column.Reference is not { } slot || table.Reference(slot.SourceId) is not { } source)
            {
                continue;
            }

            if (!_sources.TryGetValue(slot.SourceId, out var sourceState))
            {
                sourceState = new SourceState(source, new SeededRandom(settings.Seed, "reference:" + slot.SourceId));
                _sources[slot.SourceId] = sourceState;
                _sourceOrder.Add(slot.SourceId);
            }

            sourceState.Members.Add(index);
        }

        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < _columns.Length; i++)
        {
            positions.TryAdd(_columns[i].Column.Name, i);
        }

        var groups = new List<int[]>();
        foreach (var group in table.UniqueGroups)
        {
            var indices = new List<int>(group.Count);
            var settled = false;
            foreach (var name in group)
            {
                if (positions.TryGetValue(name, out var index))
                {
                    // A member that never repeats already keeps the key unique.
                    if (_columns[index].Column.IsUnique || _columns[index].Settings.Kind == RowGeneratorKind.Sequence)
                    {
                        settled = true;
                        break;
                    }

                    indices.Add(index);
                }
                else if (table.Column(name)?.Ownership == ServerOwnership.Assigned)
                {
                    // So does one the server numbers itself.
                    settled = true;
                    break;
                }

                // Any other member left to the server takes its default, the same in every row, so the rest of the
                // key has to be unique on its own.
            }

            if (!settled && indices.Count > 0)
            {
                groups.Add([.. indices]);
            }
        }

        _groups = [.. groups];
        _groupSeen = [.. _groups.Select(_ => new HashSet<RowFingerprint>())];
        _groupRandoms = [.. _groups.Select((_, i) => new SeededRandom(settings.Seed, "key:" + i.ToString(CultureInfo.InvariantCulture)))];
    }

    /// <summary>The columns each row holds a value for, in table order; the rest are left to the server.</summary>
    public IReadOnlyList<string> ColumnNames { get; }

    public List<object?[]> NextRows(int count)
    {
        var rows = new List<object?[]>(count);
        for (var i = 0; i < count; i++)
        {
            rows.Add(NextRow());
        }

        return rows;
    }

    public object?[] NextRow()
    {
        var drawn = DrawSources();
        var row = new object?[_columns.Length];
        for (var i = 0; i < _columns.Length; i++)
        {
            row[i] = Value(i, drawn);
        }

        if (_groups.Length > 0)
        {
            EnforceGroups(row, drawn);
        }

        _ordinal++;
        return row;
    }

    // MARK: Columns

    private object? Value(int index, Dictionary<string, int> drawn)
    {
        ref var state = ref _columns[index];
        var column = state.Column;
        if (!column.IsUnique && column.IsNullable && state.Random.Chance(state.Settings.NullRatio))
        {
            return null;
        }

        if (state.Settings.Kind == RowGeneratorKind.Reference)
        {
            return ReferenceValue(index, drawn);
        }

        var value = Draw(index);
        if (!column.IsUnique)
        {
            return value;
        }

        var attempts = 1;
        while (!Remember(value, index))
        {
            if (attempts >= RandomAttempts)
            {
                return Fallback(index, value);
            }

            value = Draw(index);
            attempts++;
        }

        return value;
    }

    private bool IsKey(object? value) => !(value is null && _nullsAreDistinct);

    private bool Remember(object? value, int index) => !IsKey(value) || _columns[index].Seen.Add(RowFingerprint.Of(value));

    private bool IsTaken(object? value, int index) => IsKey(value) && _columns[index].Seen.Contains(RowFingerprint.Of(value));

    private void Forget(object? value, int index) => _columns[index].Seen.Remove(RowFingerprint.Of(value));

    private object? Fallback(int index, object? value)
    {
        ref var state = ref _columns[index];
        var name = state.Column.Name;
        if (state.Settings.Kind.TakesDisambiguatingSuffix() && value is string text)
        {
            while (state.Suffix < int.MaxValue - 1)
            {
                state.Suffix++;
                if (Disambiguate(text, state.Suffix, state) is not { } candidate)
                {
                    break;
                }

                if (Remember(candidate, index))
                {
                    return candidate;
                }
            }

            throw RowGenerationException.Exhausted([name]);
        }

        if (state.DomainSize is not { } size || size <= 0 || !state.WalksDomain)
        {
            throw RowGenerationException.Exhausted([name]);
        }

        // A pattern is drawn character by character, so its walk starts anywhere rather than at the last draw.
        var position = state.Settings.Kind == RowGeneratorKind.Pattern ? state.Random.Integer(0, size - 1) : state.LastPosition;
        for (long step = 0; step < Math.Min(size, WalkLimit); step++)
        {
            position = position + 1 >= size ? 0 : position + 1;
            var candidate = DomainValue(state, position);
            if (candidate is not null && Remember(candidate, index))
            {
                state.LastPosition = position;
                return candidate;
            }
        }

        throw RowGenerationException.Exhausted([name]);
    }

    private static string? Disambiguate(string text, int suffix, ColumnState state)
    {
        var limit = state.Column.MaxLength;
        if (state.Settings.Kind == RowGeneratorKind.Email && text.LastIndexOf('@') is var at and >= 0)
        {
            var tail = string.Create(CultureInfo.InvariantCulture, $".{suffix}{text[at..]}");
            return Clipped(text[..at], tail.Length, limit) is { } local ? local + tail : null;
        }

        var spaced = string.Create(CultureInfo.InvariantCulture, $" {suffix}");
        return Clipped(text, spaced.Length, limit) is { } head ? head + spaced : null;
    }

    private static string? Clipped(string text, int tailLength, int? limit)
    {
        if (limit is not { } max)
        {
            return text;
        }

        var room = max - tailLength;
        return room < 1 ? null : text.Length <= room ? text : text[..room];
    }

    // MARK: Foreign keys

    // A foreign key that shares nothing with another draws once; the loop is kept so a unique member that cannot claim
    // a row fails the same way macOS reports it.
    private Dictionary<string, int> DrawSources()
    {
        var drawn = new Dictionary<string, int>(_sourceOrder.Count, StringComparer.Ordinal);
        foreach (var id in _sourceOrder)
        {
            DrawSource(id, drawn);
        }

        return drawn;
    }

    // One draw per foreign key and row, so every column of a key over several columns comes from one referenced row.
    // A key column that must not repeat claims its value here, before the row is built around it.
    private void DrawSource(string id, Dictionary<string, int> drawn)
    {
        var state = _sources[id];
        var count = state.Source.Tuples.Count;
        if (count == 0)
        {
            return;
        }

        var uniqueMembers = state.Members.Where(m => _columns[m].Column.IsUnique).ToArray();
        if (uniqueMembers.Length == 0)
        {
            drawn[id] = state.Random.Index(count);
            return;
        }

        for (var attempt = 0; attempt < RandomAttempts; attempt++)
        {
            var pick = state.Random.Index(count);
            if (Claim(pick, state, uniqueMembers))
            {
                drawn[id] = pick;
                return;
            }
        }

        var start = state.Random.Index(count);
        for (var step = 1; step <= count; step++)
        {
            var pick = (start + step) % count;
            if (Claim(pick, state, uniqueMembers))
            {
                drawn[id] = pick;
                return;
            }
        }

        throw RowGenerationException.Exhausted(uniqueMembers.Select(m => _columns[m].Column.Name));
    }

    private bool Claim(int pick, SourceState source, int[] members)
    {
        var tuple = source.Source.Tuples[pick];
        foreach (var member in members)
        {
            if (IsTaken(TupleValue(tuple, member), member))
            {
                return false;
            }
        }

        foreach (var member in members)
        {
            Remember(TupleValue(tuple, member), member);
        }

        return true;
    }

    private void Release(string id, Dictionary<string, int> drawn)
    {
        if (!drawn.TryGetValue(id, out var picked) || !_sources.TryGetValue(id, out var state) || picked >= state.Source.Tuples.Count)
        {
            return;
        }

        foreach (var member in state.Members)
        {
            if (_columns[member].Column.IsUnique)
            {
                Forget(TupleValue(state.Source.Tuples[picked], member), member);
            }
        }
    }

    private object? TupleValue(object?[] tuple, int index) =>
        _columns[index].Column.Reference is { } slot && slot.Position < tuple.Length ? tuple[slot.Position] : null;

    private object? ReferenceValue(int index, Dictionary<string, int> drawn) =>
        _columns[index].Column.Reference is { } slot && _sources.TryGetValue(slot.SourceId, out var source) && drawn.TryGetValue(slot.SourceId, out var picked)
            ? TupleValue(source.Source.Tuples[picked], index)
            : null;

    // MARK: Unique keys over several columns

    // Every key is checked against the finished row, so redrawing a column to settle one key cannot break another
    // key that shares it.
    private void EnforceGroups(object?[] row, Dictionary<string, int> drawn)
    {
        var attempts = 0;
        while (FirstCollidingGroup(row) is { } colliding)
        {
            attempts++;
            if (attempts < GroupAttempts)
            {
                Redraw(colliding, row, drawn);
            }
            else if (attempts < GroupAttempts + (_groups.Length * 2))
            {
                Walk(colliding, row, drawn);
            }
            else
            {
                throw RowGenerationException.Exhausted(_groups[colliding].Select(i => _columns[i].Column.Name));
            }
        }

        for (var group = 0; group < _groups.Length; group++)
        {
            var members = Members(group, row);
            if (members.All(IsKey))
            {
                _groupSeen[group].Add(RowFingerprint.Of(members));
            }
        }
    }

    private object?[] Members(int group, object?[] row)
    {
        var indices = _groups[group];
        var members = new object?[indices.Length];
        for (var i = 0; i < indices.Length; i++)
        {
            members[i] = row[indices[i]];
        }

        return members;
    }

    private int? FirstCollidingGroup(object?[] row)
    {
        for (var group = 0; group < _groups.Length; group++)
        {
            var members = Members(group, row);

            // NULL never equals NULL in a unique key on most engines, so such a row cannot collide there.
            if (members.All(IsKey) && _groupSeen[group].Contains(RowFingerprint.Of(members)))
            {
                return group;
            }
        }

        return null;
    }

    private void Redraw(int group, object?[] row, Dictionary<string, int> drawn)
    {
        var members = _groups[group];
        var touched = members
            .Where(i => _columns[i].Settings.Kind == RowGeneratorKind.Reference && _columns[i].Column.Reference is not null)
            .Select(i => _columns[i].Column.Reference!.Value.SourceId)
            .ToHashSet(StringComparer.Ordinal);
        foreach (var id in _sourceOrder.Where(touched.Contains))
        {
            Release(id, drawn);
            drawn.Remove(id);
        }

        foreach (var id in _sourceOrder.Where(touched.Contains))
        {
            DrawSource(id, drawn);
        }

        for (var index = 0; index < _columns.Length; index++)
        {
            var isMember = members.Contains(index);
            var followsSource = _columns[index].Settings.Kind == RowGeneratorKind.Reference
                && _columns[index].Column.Reference is { } slot && touched.Contains(slot.SourceId);
            if (!isMember && !followsSource)
            {
                continue;
            }

            if (_columns[index].Column.IsUnique && _columns[index].Settings.Kind != RowGeneratorKind.Reference)
            {
                Forget(row[index], index);
            }

            row[index] = Value(index, drawn);
        }
    }

    // Near the end of a small key space random draws stop finding the last free combinations, so the remaining ones
    // are walked in order from a random start. A foreign key is one dimension, its referenced rows.
    private void Walk(int group, object?[] row, Dictionary<string, int> drawn)
    {
        var members = LinkedMembers(group);
        var names = members.Select(i => _columns[i].Column.Name).ToArray();
        var dimensions = new List<(int Column, string? Source)>();
        var sizes = new List<long>();
        foreach (var index in members)
        {
            if (_columns[index].Settings.Kind == RowGeneratorKind.Reference)
            {
                if (_columns[index].Column.Reference is not { } slot)
                {
                    throw RowGenerationException.Exhausted(names);
                }

                if (dimensions.Any(d => d.Source == slot.SourceId))
                {
                    continue;
                }

                if (WalkSize(slot.SourceId) is not { } size)
                {
                    throw RowGenerationException.Exhausted(names);
                }

                dimensions.Add((-1, slot.SourceId));
                sizes.Add(size);
            }
            else
            {
                if (!_columns[index].WalksDomain || _columns[index].DomainSize is not ({ } size and > 0))
                {
                    throw RowGenerationException.Exhausted(names);
                }

                dimensions.Add((index, null));
                sizes.Add(size);
            }
        }

        long total = 1;
        foreach (var size in sizes)
        {
            if (total > WalkLimit / size)
            {
                throw RowGenerationException.Exhausted(names);
            }

            total *= size;
        }

        var start = _groupRandoms[group].Integer(0, total - 1);
        var candidate = (object?[])row.Clone();
        var picks = new Dictionary<string, int>(StringComparer.Ordinal);
        for (long step = 0; step < total; step++)
        {
            var position = (start + step) % total;
            for (var offset = dimensions.Count - 1; offset >= 0; offset--)
            {
                var local = position % sizes[offset];
                position /= sizes[offset];
                var (column, source) = dimensions[offset];
                if (source is null)
                {
                    candidate[column] = DomainValue(_columns[column], local);
                }
                else if (_sources.TryGetValue(source, out var state))
                {
                    picks[source] = (int)local;
                    foreach (var member in state.Members)
                    {
                        candidate[member] = TupleValue(state.Source.Tuples[(int)local], member);
                    }
                }
            }

            if (FirstCollidingGroup(candidate) is null)
            {
                Array.Copy(candidate, row, row.Length);
                foreach (var (source, pick) in picks)
                {
                    drawn[source] = pick;
                }

                return;
            }
        }

        throw RowGenerationException.Exhausted(names);
    }

    // Keys that share a column are walked together: settling one alone can leave no free value for the other.
    private int[] LinkedMembers(int group)
    {
        var members = _groups[group].ToHashSet();
        var changed = true;
        while (changed)
        {
            changed = false;
            foreach (var other in _groups)
            {
                if (members.Overlaps(other) && !members.IsSupersetOf(other))
                {
                    members.UnionWith(other);
                    changed = true;
                }
            }
        }

        return [.. members.Order()];
    }

    // A foreign key is walked over its referenced rows when nothing else depends on which one it picks.
    private long? WalkSize(string id) =>
        _sources.TryGetValue(id, out var state) && !state.Members.Any(m => _columns[m].Column.IsUnique) ? state.Source.Tuples.Count : null;

    // MARK: Values

    private object? Draw(int index)
    {
        ref var state = ref _columns[index];
        var settings = state.Settings;
        object value;
        switch (settings.Kind)
        {
            case RowGeneratorKind.ServerDefault or RowGeneratorKind.Reference:
                return null;
            case RowGeneratorKind.Sequence:
                value = unchecked(settings.IntegerMinimum + (settings.SequenceStep * _ordinal));
                break;
            case RowGeneratorKind.IntegerRange when state.DomainSize is null && settings.IntegerMinimum <= settings.IntegerMaximum:
                value = state.Random.Integer(settings.IntegerMinimum, settings.IntegerMaximum);
                break;
            case RowGeneratorKind.DecimalRange when state.DomainSize is null && state.DecimalLowSteps <= state.DecimalHighSteps:
                value = RowValueText.Decimal(state.Random.Integer(state.DecimalLowSteps, state.DecimalHighSteps), settings.DecimalScale);
                break;
            case RowGeneratorKind.IntegerRange or RowGeneratorKind.DecimalRange or RowGeneratorKind.List
                or RowGeneratorKind.Date or RowGeneratorKind.DateTime or RowGeneratorKind.Time:
            {
                if (state.DomainSize is not ({ } size and > 0))
                {
                    return null;
                }

                var position = state.Random.Integer(0, size - 1);
                state.LastPosition = position;
                return DomainValue(state, position);
            }

            case RowGeneratorKind.Boolean:
            {
                bool isTrue;
                if (state.Column.IsUnique)
                {
                    isTrue = state.Random.Index(2) == 1;
                    state.LastPosition = isTrue ? 1 : 0;
                }
                else
                {
                    isTrue = state.Random.Chance(settings.TrueRatio);
                }

                value = isTrue;
                break;
            }

            case RowGeneratorKind.Text:
                value = Lorem(ref state);
                break;
            case RowGeneratorKind.FirstName:
                value = Pick(RowValueVocabulary.FirstNames, ref state);
                break;
            case RowGeneratorKind.LastName:
                value = Pick(RowValueVocabulary.LastNames, ref state);
                break;
            case RowGeneratorKind.FullName:
                value = Pick(RowValueVocabulary.FirstNames, ref state) + " " + Pick(RowValueVocabulary.LastNames, ref state);
                break;
            case RowGeneratorKind.Email:
                value = Email(ref state);
                break;
            case RowGeneratorKind.Phone:
            {
                var area = state.Random.Integer(200, 999);
                var exchange = state.Random.Integer(200, 999);
                var line = state.Random.Integer(0, 9_999);
                value = string.Create(CultureInfo.InvariantCulture, $"+1-{area}-{exchange}-{line:D4}");
                break;
            }

            case RowGeneratorKind.StreetAddress:
            {
                var number = state.Random.Integer(1, 9_999);
                var street = Pick(RowValueVocabulary.StreetNames, ref state);
                var suffix = Pick(RowValueVocabulary.StreetSuffixes, ref state);
                value = string.Create(CultureInfo.InvariantCulture, $"{number} {street} {suffix}");
                break;
            }

            case RowGeneratorKind.City:
                value = Pick(RowValueVocabulary.Cities, ref state);
                break;
            case RowGeneratorKind.Country:
                value = Pick(RowValueVocabulary.Countries, ref state);
                break;
            case RowGeneratorKind.Uuid:
                value = Uuid(ref state, settings.UuidVersion);
                break;
            case RowGeneratorKind.Pattern:
                value = RowGenerationPattern.Expand(settings.Pattern, ref state.Random);
                break;
            case RowGeneratorKind.Json:
            {
                var identifier = state.Random.Integer(1, 100_000);
                var label = Pick(RowValueVocabulary.Words, ref state) + " " + Pick(RowValueVocabulary.Words, ref state);
                var active = state.Random.Chance(0.5) ? "true" : "false";
                value = string.Create(CultureInfo.InvariantCulture, $"{{\"id\":{identifier},\"label\":\"{label}\",\"active\":{active}}}");
                break;
            }

            default:
                return null;
        }

        return Fitted(value, state.Column);
    }

    private static object? DomainValue(in ColumnState state, long position)
    {
        var settings = state.Settings;
        object? value = settings.Kind switch
        {
            RowGeneratorKind.IntegerRange => unchecked(settings.IntegerMinimum + position),
            RowGeneratorKind.DecimalRange => RowValueText.Decimal(unchecked(state.DecimalLowSteps + position), settings.DecimalScale),
            RowGeneratorKind.List => position < state.ListValues.Length ? state.ListValues[position] : null,
            RowGeneratorKind.Boolean => position == 1,
            RowGeneratorKind.Date => DateOnly.FromDayNumber((int)(settings.DateStart.DayNumber + position)),
            RowGeneratorKind.DateTime => new DateTime((settings.DateStart.DayNumber * TimeSpan.TicksPerDay) + (position * TimeSpan.TicksPerSecond), DateTimeKind.Unspecified),
            RowGeneratorKind.Time => new TimeOnly(position * TimeSpan.TicksPerSecond),
            RowGeneratorKind.Pattern => RowGenerationPattern.ValueAt(position, settings.Pattern, state.Column.MaxLength),
            _ => null,
        };
        return value is null ? null : Fitted(value, state.Column);
    }

    /// <summary>A text column takes every value as its invariant text, cut to the column's length.</summary>
    private static object Fitted(object value, RowGenerationColumn column)
    {
        if (column.ValueClass == RowValueClass.Uuid && value is string uuid && Guid.TryParse(uuid, out var guid))
        {
            return guid;
        }

        if (column.ValueClass is not (RowValueClass.Text or RowValueClass.Json or RowValueClass.Enumeration) && value is not string)
        {
            return value;
        }

        var text = value as string ?? RowValueText.Invariant(value)!;
        return column.MaxLength is { } max && text.Length > max ? text[..Math.Max(0, max)] : text;
    }

    private static string Pick(string[] values, ref ColumnState state) => values[state.Random.Index(values.Length)];

    private static string Lorem(ref ColumnState state)
    {
        var low = Math.Max(0, state.Settings.MinLength);
        var target = (int)state.Random.Integer(low, Math.Max(low, state.Settings.MaxLength));
        if (target <= 0)
        {
            return string.Empty;
        }

        var text = new System.Text.StringBuilder(target + 16);
        while (text.Length < target)
        {
            var word = Pick(RowValueVocabulary.Words, ref state);
            if (text.Length == 0)
            {
                text.Append(char.ToUpperInvariant(word[0])).Append(word, 1, word.Length - 1);
            }
            else
            {
                text.Append(' ').Append(word);
            }
        }

        text.Length = target;
        while (text.Length > 1 && text[^1] == ' ')
        {
            text.Length--;
        }

        return text.ToString();
    }

    private static string Email(ref ColumnState state)
    {
        var first = Pick(RowValueVocabulary.FirstNames, ref state).ToLowerInvariant();
        var last = Pick(RowValueVocabulary.LastNames, ref state).ToLowerInvariant();
        var number = state.Random.Chance(0.5) ? state.Random.Integer(1, 999).ToString(CultureInfo.InvariantCulture) : string.Empty;
        var domain = Pick(RowValueVocabulary.EmailDomains, ref state);
        return $"{first}.{last}{number}@{domain}";
    }

    private object Uuid(ref ColumnState state, UuidVersion version)
    {
        Span<byte> bytes = stackalloc byte[16];
        for (var i = 0; i < bytes.Length; i++)
        {
            bytes[i] = (byte)state.Random.Next();
        }

        if (version == UuidVersion.V7)
        {
            var milliseconds = unchecked((ulong)(UuidEpochMilliseconds + _ordinal));
            for (var i = 0; i < 6; i++)
            {
                bytes[i] = (byte)(milliseconds >> (8 * (5 - i)));
            }

            bytes[6] = (byte)(0x70 | (bytes[6] & 0x0F));
        }
        else
        {
            bytes[6] = (byte)(0x40 | (bytes[6] & 0x0F));
        }

        bytes[8] = (byte)(0x80 | (bytes[8] & 0x3F));
        var guid = new Guid(bytes, bigEndian: true);
        return state.Column.ValueClass == RowValueClass.Uuid ? guid : guid.ToString("D");
    }

    private struct ColumnState
    {
        public ColumnState(RowGenerationColumn column, RowGeneratorSettings settings, ulong seed, RowGenerationTable table)
        {
            Column = column;
            Settings = settings;
            Random = new SeededRandom(seed, "column:" + column.Name);
            ListValues = [.. settings.Values.Where(v => v.Length > 0).Distinct(StringComparer.Ordinal)];
            DecimalLowSteps = RowGenerationValidation.Steps(settings.DecimalMinimum, settings.DecimalScale);
            DecimalHighSteps = RowGenerationValidation.Steps(settings.DecimalMaximum, settings.DecimalScale);
            DomainSize = settings.Kind switch
            {
                RowGeneratorKind.List => ListValues.Length,
                RowGeneratorKind.Reference => null,
                _ => RowGenerationValidation.DomainSize(settings, column, table),
            };
        }

        public RowGenerationColumn Column { get; }

        public RowGeneratorSettings Settings { get; }

        public SeededRandom Random;

        public HashSet<RowFingerprint> Seen { get; } = [];

        public int Suffix { get; set; }

        public long LastPosition { get; set; }

        public long? DomainSize { get; }

        public string[] ListValues { get; }

        public long DecimalLowSteps { get; }

        public long DecimalHighSteps { get; }

        /// <summary>Whether every value the generator can make has a position, so a unique column can be walked value by value.</summary>
        public readonly bool WalksDomain => Settings.Kind is RowGeneratorKind.IntegerRange or RowGeneratorKind.DecimalRange or RowGeneratorKind.List
            or RowGeneratorKind.Boolean or RowGeneratorKind.Date or RowGeneratorKind.DateTime or RowGeneratorKind.Time or RowGeneratorKind.Pattern;
    }

    private sealed class SourceState(ReferenceSource source, SeededRandom random)
    {
        public ReferenceSource Source { get; } = source;

        public SeededRandom Random = random;

        public List<int> Members { get; } = [];
    }
}
