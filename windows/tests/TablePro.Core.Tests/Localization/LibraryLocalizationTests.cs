using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using TablePro.Core.Localization;

namespace TablePro.Core.Tests.Localization;

/// <summary>
/// Guards the text the libraries compose (Core, Storage, Ssh, Ai and the drivers), which lives in
/// src/&lt;Project&gt;/Resources/&lt;Area&gt;.resx with one satellite file per language, as LocalizationTests guards the
/// app's .resw files. A dropped key, a missing placeholder or an English sentence left in a throw shows up here rather
/// than on a user's screen.
/// </summary>
public sealed partial class LibraryLocalizationTests
{
    /// <summary>The languages beside English, matching the app's Strings folders.</summary>
    public static TheoryData<string> Translations { get; } = new() { "fr", "ko", "tr", "vi", "zh-Hans", "zh-Hant" };

    private static readonly string SourceRoot = FindSourceRoot();

    /// <summary>
    /// Projects whose user-facing text must be translated. TablePro.Mcp is left out on purpose: its text is protocol
    /// and tool results read by AI clients, which stay English.
    /// </summary>
    private static readonly string[] LocalizedProjects = [.. Directory.GetDirectories(SourceRoot)
        .Select(Path.GetFileName)
        .OfType<string>()
        .Where(p => p is "TablePro.Core" or "TablePro.Storage" or "TablePro.Ssh" or "TablePro.Ai"
            || p.StartsWith("TablePro.Drivers.", StringComparison.Ordinal))
        .Order(StringComparer.Ordinal)];

    [Fact]
    public void CoreHasTheSharedDriverArea() =>
        Assert.True(File.Exists(Path.Combine(SourceRoot, "TablePro.Core", "Resources", "Driver.resx")));

    [Fact]
    public void EveryEnglishFileHasEveryTranslationAndNoStrayLanguage()
    {
        var problems = new List<string>();
        foreach (var english in EnglishFiles())
        {
            var stem = english[..^".resx".Length];
            problems.AddRange(Translations.Select(t => (string)t.Data)
                .Where(language => !File.Exists($"{stem}.{language}.resx"))
                .Select(language => $"{Relative(stem)}.{language}.resx is missing"));
        }

        foreach (var file in AllResxFiles())
        {
            var parts = Path.GetFileName(file).Split('.');
            if (parts.Length > 2 && !Translations.Any(t => (string)t.Data == string.Join('.', parts[1..^1])))
            {
                problems.Add($"{Relative(file)} is not a shipped language");
            }
        }

        Assert.Empty(problems);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    public void EveryEnglishKeyExistsInTheTranslation(string language)
    {
        var problems = new List<string>();
        foreach (var (stem, english) in EnglishResources())
        {
            var translated = Read($"{stem}.{language}.resx");
            problems.AddRange(english.Keys.Except(translated.Keys).Select(k => $"missing {Relative(stem)}/{k}"));
            problems.AddRange(translated.Keys.Except(english.Keys).Select(k => $"extra {Relative(stem)}/{k}"));
        }

        Assert.Empty(problems);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    [InlineData("en")]
    public void NoValueIsEmpty(string language)
    {
        var empty = from pair in EnglishResources()
                    let entries = language == "en" ? pair.Entries : Read($"{pair.Stem}.{language}.resx")
                    from entry in entries
                    where entry.Value.Trim().Length == 0
                    select $"{Relative(pair.Stem)}/{entry.Key}";

        Assert.Empty(empty);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    public void PlaceholdersMatchTheEnglish(string language)
    {
        var mismatched = new List<string>();
        foreach (var (stem, english) in EnglishResources())
        {
            var translated = Read($"{stem}.{language}.resx");
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
                    mismatched.Add($"{Relative(stem)}/{key}: [{string.Join(',', got.Order())}] vs English [{string.Join(',', want.Order())}]");
                }
            }
        }

        Assert.Empty(mismatched);
    }

    [Theory]
    [MemberData(nameof(Translations))]
    [InlineData("en")]
    public void MessagesFormatWithoutError(string language)
    {
        var broken = new List<string>();
        var args = Enumerable.Range(0, 10).Select(_ => (object)"x").ToArray();
        foreach (var (stem, english) in EnglishResources())
        {
            var entries = language == "en" ? english : Read($"{stem}.{language}.resx");
            foreach (var (key, value) in entries)
            {
                if (Placeholders(english.GetValueOrDefault(key, string.Empty)).Count == 0)
                {
                    continue;
                }

                try
                {
                    _ = string.Format(CultureInfo.InvariantCulture, value, args);
                }
                catch (FormatException)
                {
                    broken.Add($"{Relative(stem)}/{key} [{language}]");
                }
            }
        }

        Assert.Empty(broken);
    }

    [Fact]
    public void PluralKeysComeInPairs()
    {
        var unpaired = from pair in EnglishResources()
                       from key in pair.Entries.Keys
                       let partner = key.EndsWith("_One", StringComparison.Ordinal) ? key[..^4] + "_Other"
                           : key.EndsWith("_Other", StringComparison.Ordinal) ? key[..^6] + "_One"
                           : null
                       where partner is not null && !pair.Entries.ContainsKey(partner)
                       select $"{Relative(pair.Stem)}/{key}";

        Assert.Empty(unpaired);
    }

    [Fact]
    public void EveryKeyTheCodeUsesExistsInEnglish()
    {
        var accessors = Accessors();
        var missing = new List<string>();
        var used = 0;
        foreach (var file in SourceFiles(Directory.GetDirectories(SourceRoot)))
        {
            foreach (Match match in CodeKey().Matches(File.ReadAllText(file)))
            {
                var accessor = match.Groups["class"].Value;
                if (!accessors.TryGetValue(accessor, out var project))
                {
                    missing.Add($"{Path.GetFileName(file)}: {accessor} reads no Resources folder");
                    continue;
                }

                var (area, name) = (match.Groups["area"].Value, match.Groups["name"].Value);
                var english = Read(Path.Combine(SourceRoot, project, "Resources", area + ".resx"), mustExist: false);
                var names = match.Groups["method"].Value == "Plural" ? new[] { name + "_One", name + "_Other" } : [name];
                missing.AddRange(names.Where(n => !english.ContainsKey(n))
                    .Select(n => $"{Path.GetFileName(file)}: {accessor} {area}/{n}"));
                used++;
            }
        }

        Assert.True(missing.Count == 0, string.Join('\n', missing));
        Assert.True(used > 0);
    }

    [Fact]
    public void EveryResourceAreaIsReadFromCode()
    {
        var accessors = Accessors();
        var code = string.Join('\n', SourceFiles(Directory.GetDirectories(SourceRoot)).Select(File.ReadAllText));
        var unused = from english in EnglishFiles()
                     let project = Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(english)))!
                     let area = Path.GetFileNameWithoutExtension(english)
                     let readers = accessors.Where(a => a.Value == project).Select(a => a.Key).ToArray()
                     where !readers.Any(r => code.Contains($"{r}.Get(\"{area}/", StringComparison.Ordinal)
                         || code.Contains($"{r}.Format(\"{area}/", StringComparison.Ordinal)
                         || code.Contains($"{r}.Plural(\"{area}/", StringComparison.Ordinal))
                     select Relative(english);

        Assert.Empty(unused);
    }

    /// <summary>
    /// Flags English left in the places a user reads it: the message of a thrown exception, a message-like property
    /// set from a literal, and any literal that reads as a sentence. Each entry of <see cref="AllowedEnglish"/> says why
    /// its text stays English.
    /// </summary>
    [Fact]
    public void NoEnglishMessageIsLeftInTheLibraries()
    {
        var found = new List<string>();
        foreach (var file in SourceFiles(LocalizedProjects.Select(p => Path.Combine(SourceRoot, p))))
        {
            var relative = Relative(file).Replace('\\', '/');
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                var line = lines[i];
                var trimmed = line.TrimStart();
                if (trimmed.StartsWith("//", StringComparison.Ordinal) || trimmed.StartsWith('['))
                {
                    continue;
                }

                foreach (var literal in EnglishMessages(line))
                {
                    if (!AllowedEnglish.Any(a => relative.EndsWith(a.File, StringComparison.Ordinal)
                        && (a.Text.Length == 0 || literal.Contains(a.Text, StringComparison.Ordinal))))
                    {
                        found.Add($"{relative}:{i + 1}: {literal}");
                    }
                }
            }
        }

        // Every line is listed, since xunit would shorten a collection to its first few items.
        Assert.True(found.Count == 0, $"{found.Count} English messages:\n{string.Join('\n', found)}");
    }

    [Theory]
    [InlineData("throw new InvalidOperationException(\"The host is required.\");", true)]
    [InlineData("throw new NotSupportedException($\"{engine} cannot run a raw WHERE clause.\");", true)]
    [InlineData("Message = \"Could not connect\",", true)]
    [InlineData("return new PlanNote(\"Rows were estimated from statistics.\");", true)]
    [InlineData("throw new InvalidOperationException(CoreStrings.Get(\"Connection/HostRequired\"));", false)]
    [InlineData("var sql = \"SELECT name FROM sqlite_master WHERE type = 'table'\";", false)]
    [InlineData("Status = \"ok\",", false)]
    [InlineData("throw new ArgumentNullException(nameof(value));", false)]
    [InlineData("Trace.TraceWarning(\"The debug target was not confirmed ended before the stop deadline.\");", false)]
    public void TheScannerFindsEnglishMessagesOnly(string line, bool flagged) =>
        Assert.Equal(flagged, EnglishMessages(line).Any());

    [Fact]
    public void CoreTextFollowsTheUiLanguage()
    {
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");
            Assert.Equal("Aucune définition n\x2019a été trouvée pour t.", CoreStrings.Format("Driver/NoDefinitionFor", "t"));

            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("zh-TW");
            Assert.Equal("找不到 t 的定義。", CoreStrings.Format("Driver/NoDefinitionFor", "t"));

            // A language TablePro does not ship falls back to English.
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("de-DE");
            Assert.Equal("No definition was found for t.", CoreStrings.Format("Driver/NoDefinitionFor", "t"));
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }

    [Fact]
    public void AMissingKeyShowsTheKey() =>
        Assert.Equal("Driver/NoSuchKey", CoreStrings.Get("Driver/NoSuchKey"));

    [Fact]
    public void AnUnknownAreaShowsTheKey() =>
        Assert.Equal("NoSuchArea/Key", CoreStrings.Get("NoSuchArea/Key"));

    [Theory]
    [InlineData("en", 0, false)]
    [InlineData("en", 1, true)]
    [InlineData("fr", 0, true)]
    [InlineData("fr", 1, true)]
    [InlineData("fr", 2, false)]
    [InlineData("tr", 1, true)]
    [InlineData("ko", 1, false)]
    [InlineData("zh-Hant", 1, false)]
    public void PluralRulesFollowCldr(string language, long count, bool one) =>
        Assert.Equal(one, PluralRules.IsOne(CultureInfo.GetCultureInfo(language), count));

    /// <summary>
    /// English the scanner may see in the localized projects, by file and text (empty text allows the whole file). Keep
    /// it short, and say why for each.
    /// </summary>
    private static readonly (string File, string Text)[] AllowedEnglish =
    [
        // Prompts sent to the AI model, which stay English whatever the UI language is.
        ("TablePro.Ai/Prompts/AiPromptTemplates.cs", ""),
        // Decoder errors no user reads: the only caller turns every FormatException into SurrealDb/NotCbor.
        ("TablePro.Drivers.SurrealDb/SurrealCbor.cs", ""),
        // Decoder errors no user reads: OracleDebugText.Step turns every FormatException into Oracle/Unreadable and keeps
        // this text only as the inner exception, and the invocation report treats one as no report.
        ("TablePro.Drivers.Oracle/OracleDebugPayload.cs", ""),
    ];

    private static IEnumerable<string> EnglishMessages(string line)
    {
        // Trace and debug output is log-only text, which stays English for whoever reads the log.
        if (LogCall().IsMatch(line))
        {
            yield break;
        }

        foreach (Match match in ThrowLiteral().Matches(line))
        {
            if (IsEnglish(match.Groups["text"].Value))
            {
                yield return match.Groups["text"].Value;
            }
        }

        foreach (Match match in PropertyLiteral().Matches(line))
        {
            if (IsEnglish(match.Groups["text"].Value))
            {
                yield return match.Groups["text"].Value;
            }
        }

        foreach (Match match in SentenceLiteral().Matches(line))
        {
            yield return match.Groups["text"].Value;
        }
    }

    /// <summary>Two words of letters with a space between: a phrase a person reads, not a code or an identifier.</summary>
    private static bool IsEnglish(string text) => EnglishPhrase().IsMatch(InterpolationHole().Replace(text, "x"));

    /// <summary>Each accessor class (<c>CoreStrings</c>, <c>RedisStrings</c>...) and the project whose Resources it reads.</summary>
    private static Dictionary<string, string> Accessors()
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var project in Directory.GetDirectories(SourceRoot))
        {
            foreach (var file in SourceFiles([project]))
            {
                foreach (Match match in AccessorDeclaration().Matches(File.ReadAllText(file)))
                {
                    map[match.Groups["class"].Value] = Path.GetFileName(project);
                }
            }
        }

        return map;
    }

    private static IEnumerable<string> AllResxFiles() =>
        Directory.GetDirectories(SourceRoot)
            .Select(p => Path.Combine(p, "Resources"))
            .Where(Directory.Exists)
            .SelectMany(d => Directory.GetFiles(d, "*.resx"))
            .Order(StringComparer.Ordinal);

    private static IEnumerable<string> EnglishFiles() =>
        AllResxFiles().Where(f => Path.GetFileName(f).Count(c => c == '.') == 1);

    private static IEnumerable<(string Stem, Dictionary<string, string> Entries)> EnglishResources() =>
        EnglishFiles().Select(f => (f[..^".resx".Length], Read(f)));

    private static Dictionary<string, string> Read(string path, bool mustExist = true)
    {
        var entries = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!File.Exists(path))
        {
            Assert.False(mustExist, $"Missing resource file {path}");
            return entries;
        }

        foreach (var data in XDocument.Load(path).Root!.Elements("data"))
        {
            var name = (string)data.Attribute("name")!;
            Assert.True(entries.TryAdd(name, (string?)data.Element("value") ?? string.Empty), $"Duplicate key {name} in {path}");
        }

        return entries;
    }

    private static HashSet<int> Placeholders(string text) =>
        [.. Placeholder().Matches(text).Select(m => int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture))];

    private static IEnumerable<string> SourceFiles(IEnumerable<string> projects) =>
        projects.SelectMany(p => Directory.EnumerateFiles(p, "*.cs", SearchOption.AllDirectories))
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal)
                && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal));

    private static string Relative(string path) => Path.GetRelativePath(SourceRoot, path);

    private static string FindSourceRoot([CallerFilePath] string thisFile = "") =>
        // The source path is compiled in, so the tests find the projects from any output folder.
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(thisFile)!, "..", "..", "..", "src"));

    [GeneratedRegex(@"\{(\d+)(?:[:,][^}]*)?\}")]
    private static partial Regex Placeholder();

    [GeneratedRegex(@"\b(?<class>[A-Z]\w*Strings)\.(?<method>Get|Format|Plural)\(\s*""(?<area>[A-Za-z]+)/(?<name>[A-Za-z0-9_]+)""")]
    private static partial Regex CodeKey();

    [GeneratedRegex(@"static\s+class\s+(?<class>[A-Z]\w*Strings)\b")]
    private static partial Regex AccessorDeclaration();

    [GeneratedRegex(@"throw\s+new\s+\w*Exception\(\s*\$?""(?<text>(?:[^""\\]|\\.)*)""")]
    private static partial Regex ThrowLiteral();

    [GeneratedRegex(@"\b(?:Message|Note|Notes|Warning|Error|Status|Summary|Reason|Title|Description|Detail|Hint|UndoName)\s*[:=]\s*\$?""(?<text>(?:[^""\\]|\\.)*)""")]
    private static partial Regex PropertyLiteral();

    /// <summary>A capitalized word, at least two more lowercase words, and a full stop: how a message reads.</summary>
    [GeneratedRegex(@"\$?""(?<text>(?:\{[^}""]*\}\s)?[A-Z][a-z']+(?:\s+(?:\{[^}""]*\}|[\w'’,;:()-]+)){2,}[.?!])""")]
    private static partial Regex SentenceLiteral();

    [GeneratedRegex(@"\b(?:Trace\.Trace\w+|Debug\.(?:WriteLine|Write|Print|Fail|Assert))\(")]
    private static partial Regex LogCall();

    [GeneratedRegex(@"[A-Za-z]{2,}\s+[A-Za-z]{2,}")]
    private static partial Regex EnglishPhrase();

    [GeneratedRegex(@"\{[^}]*\}")]
    private static partial Regex InterpolationHole();
}
