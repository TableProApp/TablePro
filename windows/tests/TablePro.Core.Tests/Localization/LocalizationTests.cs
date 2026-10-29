using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace TablePro.Core.Tests.Localization;

/// <summary>
/// Guards the app's translations, which live in src/TablePro.App/Strings/&lt;language&gt;/&lt;Area&gt;.resw. The files are
/// plain XML, so they are read here without the WinUI app: a missing key or a dropped placeholder fails the build
/// instead of showing an English fallback or throwing a FormatException on a user's screen.
/// </summary>
public sealed partial class LocalizationTests
{
    private const string English = "en-US";

    /// <summary>The languages the macOS app ships, which the Windows app matches.</summary>
    public static TheoryData<string> Translations { get; } = new() { "fr", "ko", "tr", "vi", "zh-Hans", "zh-Hant" };

    private static readonly string AppRoot = FindAppRoot();

    private static readonly string StringsRoot = Path.Combine(AppRoot, "Strings");

    [Fact]
    public void EveryShippedLanguageHasAFolderAndNoOtherFolderExists()
    {
        var folders = Directory.GetDirectories(StringsRoot).Select(Path.GetFileName).Order(StringComparer.Ordinal);
        var expected = Translations.Select(t => (string)t.Data).Append(English).Order(StringComparer.Ordinal);

        Assert.Equal(expected, folders);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    public void EveryEnglishKeyExistsInTheTranslation(string language)
    {
        var missing = new List<string>();
        var extra = new List<string>();
        foreach (var (area, english) in Areas(English))
        {
            var translated = Read(Path.Combine(StringsRoot, language, area + ".resw"));
            missing.AddRange(english.Keys.Except(translated.Keys).Select(k => $"{area}/{k}"));
            extra.AddRange(translated.Keys.Except(english.Keys).Select(k => $"{area}/{k}"));
        }

        Assert.Empty(missing);
        Assert.Empty(extra);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    public void TranslationsAreNotEmpty(string language)
    {
        var empty = (from pair in Areas(English)
                     let translated = Read(Path.Combine(StringsRoot, language, pair.Area + ".resw"))
                     from entry in pair.Entries
                     where entry.Value.Trim().Length > 0 && translated.TryGetValue(entry.Key, out var value) && value.Trim().Length == 0
                     select $"{pair.Area}/{entry.Key}").ToList();

        Assert.Empty(empty);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    public void PlaceholdersMatchTheEnglish(string language)
    {
        var mismatched = new List<string>();
        foreach (var (area, english) in Areas(English))
        {
            var translated = Read(Path.Combine(StringsRoot, language, area + ".resw"));
            foreach (var (key, source) in english)
            {
                if (!translated.TryGetValue(key, out var value))
                {
                    continue;
                }

                var want = Placeholders(source);
                var got = Placeholders(value);
                // A singular may say "one" in words instead of showing the count, and French uses it for zero too.
                if (key.EndsWith("_One", StringComparison.Ordinal))
                {
                    want.Remove(0);
                    got.Remove(0);
                }

                if (!want.SetEquals(got))
                {
                    mismatched.Add($"{area}/{key}: [{string.Join(',', got.Order())}] vs English [{string.Join(',', want.Order())}]");
                }
            }
        }

        Assert.Empty(mismatched);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    [InlineData(English)]
    public void FormatMessagesFormatWithoutError(string language)
    {
        var broken = new List<string>();
        // Arguments that accept any format specifier, so only the braces of the message itself are tested.
        var args = Enumerable.Range(0, 10).Select(_ => (object)new AnyFormat()).ToArray();
        foreach (var (area, english) in Areas(English))
        {
            var translated = Read(Path.Combine(StringsRoot, language, area + ".resw"));
            foreach (var (key, source) in english)
            {
                // Only messages the app passes through string.Format; a few plain texts show literal {braces}.
                if (Placeholders(source).Count == 0 || !translated.TryGetValue(key, out var value))
                {
                    continue;
                }

                try
                {
                    _ = string.Format(CultureInfo.InvariantCulture, value, args);
                }
                catch (FormatException)
                {
                    broken.Add($"{area}/{key}");
                }
            }
        }

        Assert.Empty(broken);
    }

    [Fact]
    public void PluralKeysComeInPairs()
    {
        var unpaired = new List<string>();
        foreach (var (area, english) in Areas(English))
        {
            foreach (var key in english.Keys)
            {
                var partner = key.EndsWith("_One", StringComparison.Ordinal) ? key[..^4] + "_Other"
                    : key.EndsWith("_Other", StringComparison.Ordinal) ? key[..^6] + "_One"
                    : null;
                if (partner is not null && !english.ContainsKey(partner))
                {
                    unpaired.Add($"{area}/{key}");
                }
            }
        }

        Assert.Empty(unpaired);
    }

    [Fact]
    public void EveryKeyTheAppUsesExistsInEnglish()
    {
        var english = Areas(English).ToDictionary(a => a.Area, a => a.Entries, StringComparer.Ordinal);
        var missing = new List<string>();
        foreach (var file in SourceFiles("*.cs"))
        {
            var text = File.ReadAllText(file);
            foreach (Match match in CodeKey().Matches(text))
            {
                var (area, name) = (match.Groups["area"].Value, match.Groups["name"].Value);
                var names = match.Groups["method"].Value == "Plural" ? new[] { name + "_One", name + "_Other" } : [name];
                missing.AddRange(names.Where(n => !(english.TryGetValue(area, out var entries) && entries.ContainsKey(n)))
                    .Select(n => $"{Path.GetFileName(file)}: {area}/{n}"));
            }
        }

        foreach (var file in SourceFiles("*.xaml"))
        {
            foreach (Match match in XamlUid().Matches(File.ReadAllText(file)))
            {
                var (area, name) = (match.Groups["area"].Value, match.Groups["name"].Value);
                if (!(english.TryGetValue(area, out var entries) && entries.Keys.Any(k => k == name || k.StartsWith(name + ".", StringComparison.Ordinal))))
                {
                    missing.Add($"{Path.GetFileName(file)}: x:Uid /{area}/{name}");
                }
            }
        }

        Assert.Empty(missing);
    }

    [Fact]
    public void ResourceKeysHaveNoDotsOutsideXamlProperties()
    {
        // A dot splits a key into a resource and a XAML property, so a code key with one could never be found.
        var xamlProperties = new[] { "Text", "Content", "Header", "PlaceholderText", "Title", "Label", "Description", "Message", "OnContent", "OffContent", "Subtitle" };
        var bad = from pair in Areas(English)
                  from key in pair.Entries.Keys
                  where key.Contains('.', StringComparison.Ordinal)
                  let property = key[(key.IndexOf('.', StringComparison.Ordinal) + 1)..]
                  where !xamlProperties.Contains(property) && !property.StartsWith("[using:", StringComparison.Ordinal)
                  select $"{pair.Area}/{key}";

        Assert.Empty(bad);
    }

    [Fact]
    public void NoXamlFileHasLiteralUserFacingText()
    {
        var literals = new List<string>();
        foreach (var file in SourceFiles("*.xaml"))
        {
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                foreach (Match match in XamlLiteral().Matches(lines[i]))
                {
                    if (!IsAllowedLiteral(match.Groups["value"].Value))
                    {
                        literals.Add($"{Path.GetFileName(file)}:{i + 1}: {match.Value}");
                    }
                }
            }
        }

        Assert.Empty(literals);
    }

    [Theory]
    [InlineData("TablePro", true)]
    [InlineData("&#xE710;", true)]
    [InlineData("SELECT", true)]
    [InlineData("ORDER BY", true)]
    [InlineData("·", true)]
    [InlineData("12", true)]
    [InlineData("New Connection", false)]
    [InlineData("Cancel", false)]
    [InlineData("Rows", false)]
    public void LiteralAllowListKeepsGlyphsBrandAndSqlOnly(string value, bool allowed) =>
        Assert.Equal(allowed, IsAllowedLiteral(value));

    [Fact]
    public void LiteralAllowListKeepsPrivateUseIconGlyphs() =>
        Assert.True(IsAllowedLiteral(((char)0xE710).ToString()));

    /// <summary>
    /// Text a XAML file may spell out: the brand, icon glyphs (private-use characters, which are not letters), numbers
    /// and punctuation, and SQL keywords, which stay English in every language. Anything with a word in it belongs in a
    /// .resw file.
    /// </summary>
    private static bool IsAllowedLiteral(string value) =>
        value is "TablePro"
        || !value.Any(char.IsLetter)
        || value.StartsWith("&#x", StringComparison.Ordinal)
        || SqlKeywords().IsMatch(value);

    private static HashSet<int> Placeholders(string text) =>
        [.. Placeholder().Matches(text).Select(m => int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture))];

    private static IEnumerable<(string Area, Dictionary<string, string> Entries)> Areas(string language) =>
        Directory.GetFiles(Path.Combine(StringsRoot, language), "*.resw")
            .Order(StringComparer.Ordinal)
            .Select(f => (Path.GetFileNameWithoutExtension(f), Read(f)));

    private static Dictionary<string, string> Read(string path)
    {
        Assert.True(File.Exists(path), $"Missing resource file {path}");
        var entries = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var data in XDocument.Load(path).Root!.Elements("data"))
        {
            var name = (string)data.Attribute("name")!;
            Assert.True(entries.TryAdd(name, (string?)data.Element("value") ?? string.Empty), $"Duplicate key {name} in {path}");
        }

        return entries;
    }

    private static IEnumerable<string> SourceFiles(string pattern) =>
        Directory.EnumerateFiles(AppRoot, pattern, SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)
                && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal));

    private static string FindAppRoot([CallerFilePath] string thisFile = "")
    {
        // The source path is compiled in, so the tests find the app's files from any output folder.
        var windows = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(thisFile)!, "..", "..", ".."));
        return Path.Combine(windows, "src", "TablePro.App");
    }

    private sealed class AnyFormat : IFormattable
    {
        public string ToString(string? format, IFormatProvider? formatProvider) => "x";

        public override string ToString() => "x";
    }

    [GeneratedRegex(@"\{(\d+)(?:[:,][^}]*)?\}")]
    private static partial Regex Placeholder();

    [GeneratedRegex(@"Strings\.(?<method>Get|Format|Plural)\(\s*""(?<area>[A-Za-z]+)/(?<name>[A-Za-z0-9_]+)""\s*[,)]")]
    private static partial Regex CodeKey();

    [GeneratedRegex(@"x:Uid=""/(?<area>[A-Za-z]+)/(?<name>[A-Za-z0-9_]+)""")]
    private static partial Regex XamlUid();

    [GeneratedRegex(@"(?<![\w.:])(?:Text|Content|Header|PlaceholderText|Title|Label|Description|Message|OnContent|OffContent|ToolTipService\.ToolTip|AutomationProperties\.Name)=""(?<value>[^""{][^""]*)""|<x:String>(?<value>[^<]+)</x:String>")]
    private static partial Regex XamlLiteral();

    [GeneratedRegex(@"^(?:SELECT|INSERT|UPDATE|DELETE|WHERE|FROM|JOIN|NULL|NOT NULL|ORDER BY|GROUP BY|LIMIT|AND|OR|ASC|DESC|CASCADE|NO ACTION|SET NULL|SET DEFAULT|RESTRICT)$")]
    private static partial Regex SqlKeywords();
}
