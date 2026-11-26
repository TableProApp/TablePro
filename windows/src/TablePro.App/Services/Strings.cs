using TablePro.Graphics;
using TablePro.Interop;

namespace TablePro.App.Services;

// Strings/en-US/Resources.resw, the same resources XAML reads through x:Uid and the controls through HostStrings.
internal static class Strings
{
    // Empty for a name with no string, such as an error code with no wording yet.
    public static string Get(string name) => HostStrings.Get(name);

    public static string Format(string name, params object?[] values) => HostStrings.Format(name, values);

    // name_one, name_few and so on by the language's plural rules, else name_other; the count only picks the form.
    public static string Plural(string name, long count, params object?[] values) =>
        HostStrings.Plural(name, count, values);

    public static string FileSize(long bytes) => HostStrings.FileSize(bytes);

    // Sentences one after another, with what the language puts between two; empty parts are left out.
    public static string Sentences(params string?[] parts)
    {
        ArgumentNullException.ThrowIfNull(parts);
        var text = string.Empty;
        foreach (var part in parts)
        {
            if (!string.IsNullOrEmpty(part))
            {
                text = text.Length == 0 ? part : Format("JoinSentences", text, part);
            }
        }
        return text;
    }

    // Names or phrases in a run, with the language's separator between them.
    public static string List(IEnumerable<string> items) => string.Join(Get("ListSeparator"), items);

    // Names in a run that ends with "and"; two take a pattern of their own, since English puts no comma between them.
    public static string ListAnd(IReadOnlyList<string> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        return items.Count switch
        {
            0 => string.Empty,
            1 => items[0],
            2 => Format("ListAndTwo", items[0], items[1]),
            _ => Format("ListAndLast", List(items.Take(items.Count - 1)), items[^1]),
        };
    }

    // A code with no wording here falls back to the server's own message, then a general one.
    public static string Error(CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        for (var index = error.Codes.Count - 1; index >= 0; index--)
        {
            var text = Get("Error_" + error.Codes[index].Replace('.', '_'));
            if (!string.IsNullOrEmpty(text))
            {
                return error.Server is { } server ? Format("ErrorWithServerMessage", text, server.Message) : text;
            }
        }

        return error.Server?.Message ?? Format("Error_Unknown", error.Code);
    }

    public static string Error(Exception exception) => exception switch
    {
        TableProException core => Error(core.Error),
        _ => exception.Message,
    };
}
