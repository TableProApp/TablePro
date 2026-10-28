namespace TablePro.Core.Principals;

/// <summary>A group of the privilege checklist. Administration and engine-specific groups start collapsed, being rarely granted.</summary>
public sealed record PrivilegeCategory(string Key, string Title, int SortOrder, bool IsCollapsedByDefault)
{
    public static PrivilegeCategory Other { get; } = new("other", "Other", 4, false);

    public static PrivilegeCategory Resolve(string? key) => key switch
    {
        null or "" => Other,
        PrivilegeCategoryKeys.Data => new(key, "Data", 0, false),
        PrivilegeCategoryKeys.Structure => new(key, "Structure", 1, false),
        PrivilegeCategoryKeys.Administration => new(key, "Administration", 2, true),
        PrivilegeCategoryKeys.Dynamic => new(key, "Dynamic", 3, true),
        _ => new(key, key, 5, true),
    };
}

/// <summary>The privileges of one category, in the order the engine lists them.</summary>
public sealed record PrivilegeSection(PrivilegeCategory Category, IReadOnlyList<PrivilegeDescriptor> Privileges)
{
    public static IReadOnlyList<PrivilegeSection> Group(IEnumerable<PrivilegeDescriptor> descriptors)
    {
        var order = new List<PrivilegeCategory>();
        var buckets = new Dictionary<PrivilegeCategory, List<PrivilegeDescriptor>>();
        foreach (var descriptor in descriptors)
        {
            var category = PrivilegeCategory.Resolve(descriptor.Category);
            if (!buckets.TryGetValue(category, out var bucket))
            {
                bucket = [];
                buckets[category] = bucket;
                order.Add(category);
            }

            bucket.Add(descriptor);
        }

        return order.OrderBy(c => c.SortOrder).Select(c => new PrivilegeSection(c, buckets[c])).ToArray();
    }

    /// <summary>The sections with only the privileges whose label contains <paramref name="filter"/>; empty sections drop out.</summary>
    public static IReadOnlyList<PrivilegeSection> Filter(IReadOnlyList<PrivilegeSection> sections, string? filter)
    {
        if (string.IsNullOrWhiteSpace(filter))
        {
            return sections;
        }

        var text = filter.Trim();
        return sections
            .Select(s => s with { Privileges = s.Privileges.Where(p => p.Label.Contains(text, StringComparison.CurrentCultureIgnoreCase) || p.Name.Contains(text, StringComparison.OrdinalIgnoreCase)).ToArray() })
            .Where(s => s.Privileges.Count > 0)
            .ToArray();
    }
}

/// <summary>How the scope tree sums up what a principal holds on one object, so a grant three levels down is still visible.</summary>
public abstract record ScopeSummary
{
    public const int MaximumNamesShown = 2;

    private protected ScopeSummary()
    {
    }

    public static ScopeSummary Make(IReadOnlyList<string> granted, IReadOnlyList<PrivilegeDescriptor> grantable, int descendantCount, bool hasGrantOption, bool isBrowsingRestricted)
    {
        if (isBrowsingRestricted)
        {
            return new BrowsingRestricted([.. granted.Order(StringComparer.Ordinal)]);
        }

        if (grantable.Count == 0)
        {
            return descendantCount > 0 ? new DescendantsOnly(descendantCount) : new NotGrantable();
        }

        if (granted.Count == 0)
        {
            return descendantCount > 0 ? new DescendantsOnly(descendantCount) : new NoneGranted();
        }

        if (granted.Count >= grantable.Count)
        {
            return new AllGranted(granted.Count);
        }

        var sorted = granted.Order(StringComparer.Ordinal).ToArray();
        var shown = sorted.Take(MaximumNamesShown).ToArray();
        return new SomeGranted(shown, sorted.Length - shown.Length, hasGrantOption);
    }

    /// <summary>The short text the scope tree shows beside an object.</summary>
    public abstract string Text { get; }

    public sealed record NotGrantable : ScopeSummary
    {
        public override string Text => string.Empty;
    }

    public sealed record NoneGranted : ScopeSummary
    {
        public override string Text => "None";
    }

    public sealed record AllGranted(int Count) : ScopeSummary
    {
        public override string Text => $"All ({Count})";
    }

    public sealed record SomeGranted(IReadOnlyList<string> Names, int Overflow, bool HasGrantOption) : ScopeSummary
    {
        public override string Text => string.Join(", ", Names) + (Overflow > 0 ? $" +{Overflow}" : string.Empty) + (HasGrantOption ? " (grantable)" : string.Empty);
    }

    public sealed record DescendantsOnly(int Count) : ScopeSummary
    {
        public override string Text => Count == 1 ? "1 grant inside" : $"{Count} grants inside";
    }

    /// <summary>A database other than the connected one on an engine that reads grants only where it is connected.</summary>
    public sealed record BrowsingRestricted(IReadOnlyList<string> Direct) : ScopeSummary
    {
        public override string Text => Direct.Count == 0 ? "Connect to this database to browse it" : string.Join(", ", Direct);
    }
}
