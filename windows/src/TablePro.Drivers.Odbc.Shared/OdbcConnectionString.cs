using System.Buffers;
using System.Text;

namespace TablePro.Drivers.Odbc;

/// <summary>
/// An ODBC connection string written by the ODBC rules: a value that could end the pair early or start a braced
/// value is wrapped in braces with every closing brace doubled, so a password or an option typed by the user can never
/// add a keyword of its own.
/// </summary>
internal sealed class OdbcConnectionString
{
    /// <summary>The option that names another installed ODBC driver than the engine's default.</summary>
    public const string DriverOption = "odbcDriver";

    // The ODBC specification reserves these in keywords; a key holding one could not be parsed back as one key.
    private static readonly SearchValues<char> ReservedKeyCharacters = SearchValues.Create("[]{}(),;?*=!@");

    private readonly List<KeyValuePair<string, string>> _pairs = [];

    public int Count => _pairs.Count;

    public string? this[string key]
    {
        get
        {
            var index = IndexOf(key);
            return index < 0 ? null : _pairs[index].Value;
        }
    }

    /// <summary>Adds the pair, or replaces the value of a key already present whatever its case.</summary>
    public OdbcConnectionString Set(string key, string value)
    {
        ValidateKey(key);
        ArgumentNullException.ThrowIfNull(value);
        var index = IndexOf(key);
        if (index < 0)
        {
            _pairs.Add(new(key, value));
        }
        else
        {
            _pairs[index] = new(_pairs[index].Key, value);
        }

        return this;
    }

    public bool Contains(string key) => IndexOf(key) >= 0;

    public override string ToString()
    {
        var sql = new StringBuilder();
        foreach (var (key, value) in _pairs)
        {
            sql.Append(key).Append('=').Append(Escape(value)).Append(';');
        }

        return sql.ToString();
    }

    /// <summary>
    /// Braces a value that holds a separator, a brace, an equals sign or white space, which the driver manager would
    /// split on or trim; a driver name such as <c>{DM8 ODBC DRIVER}</c> is written braced as ODBC documents it. Inside
    /// braces only <c>}</c> is special, and it is doubled.
    /// </summary>
    public static string Escape(string value)
    {
        var plain = value.Length > 0 && value.AsSpan().IndexOfAny(";{}=") < 0 && !value.Any(char.IsWhiteSpace);
        return plain ? value : string.Concat("{", value.Replace("}", "}}", StringComparison.Ordinal), "}");
    }

    public static void ValidateKey(string key)
    {
        if (string.IsNullOrWhiteSpace(key) || key.Trim().Length != key.Length || key.AsSpan().IndexOfAny(ReservedKeyCharacters) >= 0)
        {
            throw new ArgumentException($"\"{key}\" is not a valid ODBC connection keyword.", nameof(key));
        }
    }

    /// <summary>The named option, matched without regard to case, or null when it is absent or blank.</summary>
    public static string? Option(IReadOnlyDictionary<string, string> options, string key)
    {
        foreach (var (name, value) in options)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }

    /// <summary>
    /// Copies every option the factory did not consume itself as an ODBC keyword. A key the factory sets from a form
    /// field is refused, so an option can never quietly weaken the TLS mode or swap the login.
    /// </summary>
    public void AddPassThrough(IReadOnlyDictionary<string, string> options, IReadOnlyCollection<string> consumed, IReadOnlyCollection<string> managed)
    {
        foreach (var (key, value) in options)
        {
            if (consumed.Contains(key, StringComparer.OrdinalIgnoreCase) || value is null)
            {
                continue;
            }

            if (managed.Contains(key, StringComparer.OrdinalIgnoreCase))
            {
                throw new ArgumentException($"The option \"{key}\" is set from the connection form; change it there instead.");
            }

            Set(key, value);
        }
    }

    private int IndexOf(string key)
    {
        for (var i = 0; i < _pairs.Count; i++)
        {
            if (string.Equals(_pairs[i].Key, key, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return -1;
    }
}
