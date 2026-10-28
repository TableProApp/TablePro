using System.Text;

namespace TablePro.Core.Import;

/// <summary>
/// An RFC 4180 reader: quoted fields may hold the delimiter, doubled quotes and line breaks. It reads one record at a
/// time, so an import of any size keeps one row in memory.
/// </summary>
public sealed class CsvReader(TextReader reader, char delimiter = ',')
{
    private readonly StringBuilder _field = new();

    /// <summary>Guesses the delimiter from the first line: the candidate that appears most outside quotes.</summary>
    public static char DetectDelimiter(string firstLine)
    {
        ReadOnlySpan<char> candidates = [',', ';', '\t', '|'];
        var best = ',';
        var bestCount = 0;
        foreach (var candidate in candidates)
        {
            var count = 0;
            var quoted = false;
            foreach (var c in firstLine)
            {
                if (c == '"')
                {
                    quoted = !quoted;
                }
                else if (c == candidate && !quoted)
                {
                    count++;
                }
            }

            if (count > bestCount)
            {
                best = candidate;
                bestCount = count;
            }
        }

        return best;
    }

    /// <summary>The next record, or null at the end. StreamReader buffers, so reading per character stays cheap.</summary>
    public string[]? ReadRecord()
    {
        var fields = new List<string>();
        _field.Clear();
        var quoted = false;
        var sawAny = false;
        while (true)
        {
            var next = reader.Read();
            if (next < 0)
            {
                if (!sawAny)
                {
                    return null;
                }

                fields.Add(_field.ToString());
                return [.. fields];
            }

            sawAny = true;
            var c = (char)next;
            if (quoted)
            {
                if (c == '"')
                {
                    if (reader.Peek() == '"')
                    {
                        reader.Read();
                        _field.Append('"');
                    }
                    else
                    {
                        quoted = false;
                    }
                }
                else
                {
                    _field.Append(c);
                }

                continue;
            }

            if (c == '"' && _field.Length == 0)
            {
                quoted = true;
            }
            else if (c == delimiter)
            {
                fields.Add(_field.ToString());
                _field.Clear();
            }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && reader.Peek() == '\n')
                {
                    reader.Read();
                }

                if (fields.Count == 0 && _field.Length == 0)
                {
                    sawAny = false;
                    continue;
                }

                fields.Add(_field.ToString());
                return [.. fields];
            }
            else
            {
                _field.Append(c);
            }
        }
    }
}
