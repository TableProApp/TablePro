using System.Globalization;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace TablePro.App.Model.Tests;

// Every word the app shows comes from Strings/en-US/Resources.resw (docs/decisions/0021-localization.md). These read
// the sources, so a word typed into XAML, set on a control in code or picked by comparing a count with one fails here.
public sealed partial class LocalizationTests
{
    private static readonly string Sources = typeof(LocalizationTests).Assembly
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .Single(attribute => attribute.Key == "Sources").Value!;

    private static readonly string[] UiProjects = ["TablePro.App", "TablePro.Editor", "TablePro.DataGrid"];

    private static readonly HashSet<string> ShownAttributes = new(StringComparer.Ordinal)
    {
        "Text", "Content", "Header", "Title", "Label", "Description", "PlaceholderText", "Message", "Subtitle",
        "PaneTitle", "PrimaryButtonText", "SecondaryButtonText", "CloseButtonText", "KeyboardAcceleratorTextOverride",
        "OnContent", "OffContent", "AccessKey", "ToolTipService.ToolTip", "AutomationProperties.Name",
        "AutomationProperties.HelpText", "AutomationProperties.FullDescription",
        "AutomationProperties.LocalizedControlType", "AutomationProperties.ItemStatus",
    };

    private static readonly XNamespace Xaml = "http://schemas.microsoft.com/winfx/2006/xaml";

    private static readonly Lazy<Dictionary<string, string>> s_strings = new(ReadStrings);

    [Fact]
    public void XamlTypesNoWordsOfItsOwn()
    {
        var found = new List<string>();
        foreach (var file in Files("*.xaml"))
        {
            foreach (var element in XDocument.Load(file).Descendants())
            {
                found.AddRange(element.Attributes()
                    .Where(attribute => attribute.Name.Namespace == XNamespace.None
                        && ShownAttributes.Contains(attribute.Name.LocalName)
                        && !attribute.Value.StartsWith('{')
                        && HasWords(attribute.Value))
                    .Select(attribute => $"{Relative(file)}: {attribute.Name.LocalName}=\"{attribute.Value}\""));
                // A resource such as a Color holds a value, not a word.
                if (element.Attribute(Xaml + "Key") is null)
                {
                    found.AddRange(element.Nodes().OfType<XText>()
                        .Where(text => HasWords(text.Value))
                        .Select(text => $"{Relative(file)}: <{element.Name.LocalName}>{text.Value.Trim()}"));
                }
            }
        }

        Assert.Empty(found);
    }

    [Fact]
    public void EveryUidHasItsStrings()
    {
        var properties = s_strings.Value.Keys
            .Where(name => name.Contains('.', StringComparison.Ordinal))
            .Select(name => name[..name.IndexOf('.', StringComparison.Ordinal)])
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var missing = Files("*.xaml")
            .SelectMany(file => XDocument.Load(file).Descendants()
                .Select(element => element.Attribute(Xaml + "Uid")?.Value)
                .OfType<string>()
                .Where(uid => !properties.Contains(uid))
                .Select(uid => $"{Relative(file)}: x:Uid=\"{uid}\""))
            .ToList();

        Assert.Empty(missing);
    }

    [Fact]
    public void CodeSetsNoWordsOnControls()
    {
        var found = new List<string>();
        foreach (var file in Files("*.cs"))
        {
            var code = File.ReadAllText(file);
            foreach (var match in ShownAssignment().Matches(code).Concat(ShownSetter().Matches(code)))
            {
                if (IsWorded(match.Groups["literal"].Value))
                {
                    found.Add($"{Relative(file)}:{Line(code, match.Index)}: {match.Value}");
                }
            }
        }

        Assert.Empty(found);
    }

    [Fact]
    public void ACountPicksItsFormByThePluralRulesNotByComparingItWithOne()
    {
        var found = Files("*.cs")
            .SelectMany(file =>
            {
                var code = File.ReadAllText(file);
                return EnglishPlural().Matches(code).Select(match => $"{Relative(file)}:{Line(code, match.Index)}: {match.Value}");
            })
            .ToList();

        Assert.Empty(found);
    }

    [Fact]
    public void EveryNameTheCodeReadsIsInTheStrings()
    {
        var strings = s_strings.Value;
        var problems = new List<string>();
        foreach (var file in Files("*.cs"))
        {
            var code = File.ReadAllText(file);
            foreach (Match match in StringsCall().Matches(code))
            {
                var name = match.Groups["name"].Value;
                var plural = match.Groups["method"].Value == "Plural";
                var where = $"{Relative(file)}:{Line(code, match.Index)}";
                foreach (var form in plural ? new[] { name + "_one", name + "_other" } : [name])
                {
                    if (!strings.TryGetValue(form, out var value))
                    {
                        problems.Add($"{where}: no string {form}");
                    }
                    else if (match.Groups["method"].Value != "Get" && !Formats(value))
                    {
                        problems.Add($"{where}: {form} is not a format: {value}");
                    }
                }
            }
        }

        Assert.Empty(problems);
    }

    [Fact]
    public void EveryFeatureSettingsListsHasItsNameAndDescription()
    {
        var missing = PlanFeatures.OnWindows
            .SelectMany(feature => new[] { "PlanFeature_" + feature.Code, "PlanFeatureDescription_" + feature.Code })
            .Where(name => !s_strings.Value.ContainsKey(name))
            .ToList();

        Assert.Empty(missing);
    }

    [Fact]
    public void EveryPluralFormHasTheOtherForm()
    {
        var strings = s_strings.Value;
        var missing = strings.Keys
            .Where(name => PluralForm().IsMatch(name))
            .Select(name => name[..name.LastIndexOf('_')] + "_other")
            .Where(other => !strings.ContainsKey(other))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        Assert.Empty(missing);
    }

    [Fact]
    public void ThePackageNamesItselfFromTheStrings()
    {
        var manifest = XDocument.Load(Path.Combine(Sources, "TablePro.App", "Package.appxmanifest"));
        var shown = new List<string>();
        foreach (var element in manifest.Descendants())
        {
            if (element.Name.LocalName is "DisplayName" or "PublisherDisplayName" or "Description")
            {
                shown.Add(element.Value);
            }
            else if (element.Name.LocalName == "VisualElements")
            {
                shown.AddRange(element.Attributes()
                    .Where(attribute => attribute.Name.LocalName is "DisplayName" or "Description")
                    .Select(attribute => attribute.Value));
            }
        }

        Assert.NotEmpty(shown);
        Assert.All(shown, value =>
        {
            Assert.StartsWith("ms-resource:", value, StringComparison.Ordinal);
            Assert.True(s_strings.Value.ContainsKey(value["ms-resource:".Length..]), value);
        });
    }

    private static IEnumerable<string> Files(string pattern) => UiProjects
        .SelectMany(project => Directory.EnumerateFiles(Path.Combine(Sources, project), pattern, SearchOption.AllDirectories))
        .Where(file => !file.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Any(part => part is "bin" or "obj"));

    private static Dictionary<string, string> ReadStrings() => XDocument
        .Load(Path.Combine(Sources, "TablePro.App", "Strings", "en-US", "Resources.resw"))
        .Root!.Elements("data")
        .ToDictionary(
            data => data.Attribute("name")!.Value,
            data => data.Element("value")?.Value ?? string.Empty,
            StringComparer.OrdinalIgnoreCase);

    private static bool HasWords(string text) => text.Any(char.IsLetter);

    // An interpolated string counts its own text, not its holes: a join of two worded values is still words to word.
    private static bool IsWorded(string literal) => literal.StartsWith('$')
        ? Hole().Replace(literal[1..].Trim('@', '"'), string.Empty).Any(character => !char.IsWhiteSpace(character))
        : HasWords(literal);

    private static bool Formats(string value)
    {
        try
        {
            _ = string.Format(CultureInfo.InvariantCulture, value, new object?[10]);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Relative(string file) => Path.GetRelativePath(Sources, file);

    private static int Line(string code, int index) => code.AsSpan(0, index).Count('\n') + 1;

    [GeneratedRegex(@"\b(?:Text|Content|Header|Title|Label|Description|PlaceholderText|Message|Subtitle|PaneTitle|PrimaryButtonText|SecondaryButtonText|CloseButtonText|KeyboardAcceleratorTextOverride|OnContent|OffContent)\s*=\s*(?<literal>\$?@?""(?:[^""\\]|\\.)*"")")]
    private static partial Regex ShownAssignment();

    [GeneratedRegex(@"\b(?:AutomationProperties\.Set(?:Name|HelpText|FullDescription|LocalizedControlType|ItemStatus)|ToolTipService\.SetToolTip)\s*\([^,;]+,\s*(?<literal>\$?@?""(?:[^""\\]|\\.)*"")")]
    private static partial Regex ShownSetter();

    [GeneratedRegex(@"[\w.\]\)]+\s*==\s*1\s*\?\s*\(?\s*(?:Strings\.|HostStrings\.|"")")]
    private static partial Regex EnglishPlural();

    [GeneratedRegex(@"\b(?:Strings|HostStrings)\.(?<method>Get|Format|Plural)\(\s*""(?<name>[^""]+)""\s*[,)]")]
    private static partial Regex StringsCall();

    [GeneratedRegex(@"_(?:zero|one|two|few|many)$")]
    private static partial Regex PluralForm();

    [GeneratedRegex(@"\{[^{}]*\}")]
    private static partial Regex Hole();
}
