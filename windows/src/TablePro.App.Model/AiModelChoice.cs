using TablePro.Interop;

namespace TablePro.App.Model;

// One entry of Settings' model list, which shows Label and saves Id.
public sealed record AiModelChoice(string Id, string Label)
{
    // Each model's name, else its id. A name two models share, as a snapshot and its base do, carries the id.
    public static IReadOnlyList<AiModelChoice> For(
        IReadOnlyList<AiModelInfo> models,
        Func<string, string> deprecated,
        Func<string, string, string> withId)
    {
        ArgumentNullException.ThrowIfNull(models);
        ArgumentNullException.ThrowIfNull(deprecated);
        ArgumentNullException.ThrowIfNull(withId);
        var shared = models
            .GroupBy(NameOf, StringComparer.Ordinal)
            .Where(group => group.Count() > 1)
            .Select(group => group.Key)
            .ToHashSet(StringComparer.Ordinal);
        return
        [
            .. models.Select(model =>
            {
                var name = NameOf(model);
                var label = shared.Contains(name) && name != model.Id ? withId(name, model.Id) : name;
                return new AiModelChoice(model.Id, model.IsDeprecated ? deprecated(label) : label);
            }),
        ];
    }

    // The model a picked or typed text names: a listed entry's id when the text is its label, else the text.
    public static string IdFor(IEnumerable<AiModelChoice> choices, string text)
    {
        ArgumentNullException.ThrowIfNull(choices);
        ArgumentNullException.ThrowIfNull(text);
        var trimmed = text.Trim();
        return choices.FirstOrDefault(choice => choice.Label == trimmed)?.Id ?? trimmed;
    }

    // The text the box shows for a model id: its entry's label, else the id itself.
    public static string LabelFor(IEnumerable<AiModelChoice> choices, string id)
    {
        ArgumentNullException.ThrowIfNull(choices);
        ArgumentNullException.ThrowIfNull(id);
        return choices.FirstOrDefault(choice => choice.Id == id)?.Label ?? id;
    }

    private static string NameOf(AiModelInfo model) =>
        string.IsNullOrWhiteSpace(model.Name) ? model.Id : model.Name;
}
