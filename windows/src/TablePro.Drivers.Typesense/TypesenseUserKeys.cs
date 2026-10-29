using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Principals;

namespace TablePro.Drivers.Typesense;

/// <summary>A Typesense API key as <c>GET /keys</c> lists it. The key's value is shown only once, when it is created.</summary>
internal sealed record TypesenseApiKey(long Id, string Description, IReadOnlyList<string> Actions, IReadOnlyList<string> Collections)
{
    /// <summary>
    /// A key has no name of its own. The description is what the person typed and the only thing that reads as a name;
    /// the id keeps two keys with the same description apart and is what a drop addresses.
    /// </summary>
    public string DisplayName => Description.Length == 0
        ? string.Create(CultureInfo.InvariantCulture, $"#{Id}")
        : string.Create(CultureInfo.InvariantCulture, $"{Description} (#{Id})");
}

/// <summary>
/// Typesense API keys projected onto principals and privileges: a key is the principal, and its actions applied to its
/// collections are the grants. A key cannot change once created, so only creating and deleting one has a request.
/// </summary>
internal sealed class TypesenseUserKeys : IPrincipalSqlGenerator
{
    /// <summary>The scope tree's one database, under which the collections are listed, as the macOS app names it.</summary>
    public const string DatabaseName = "default";

    public const string AllCollections = "*";

    private const string DefaultAction = "documents:search";

    /// <summary>
    /// The actions Typesense documents. An action is its own label, since it is what the API and its documentation call
    /// it; <c>*</c> is a real action value meaning every action, not a wildcard the app expands.
    /// </summary>
    public static readonly IReadOnlyList<PrivilegeDescriptor> Actions =
    [
        Action("*", PrivilegeCategoryKeys.Administration),
        Action("documents:search", PrivilegeCategoryKeys.Data),
        Action("documents:get", PrivilegeCategoryKeys.Data),
        Action("documents:create", PrivilegeCategoryKeys.Data),
        Action("documents:upsert", PrivilegeCategoryKeys.Data),
        Action("documents:update", PrivilegeCategoryKeys.Data),
        Action("documents:delete", PrivilegeCategoryKeys.Data),
        Action("documents:import", PrivilegeCategoryKeys.Data),
        Action("documents:export", PrivilegeCategoryKeys.Data),
        Action("documents:*", PrivilegeCategoryKeys.Data),
        Action("collections:list", PrivilegeCategoryKeys.Structure),
        Action("collections:get", PrivilegeCategoryKeys.Structure),
        Action("collections:create", PrivilegeCategoryKeys.Structure),
        Action("collections:delete", PrivilegeCategoryKeys.Structure),
        Action("collections:*", PrivilegeCategoryKeys.Structure),
        Action("aliases:*", PrivilegeCategoryKeys.Structure),
        Action("synonyms:*", PrivilegeCategoryKeys.Structure),
        Action("overrides:*", PrivilegeCategoryKeys.Structure),
        Action("keys:*", PrivilegeCategoryKeys.Administration),
        Action("metrics.json:list", PrivilegeCategoryKeys.Administration),
        Action("stats.json:list", PrivilegeCategoryKeys.Administration),
        Action("debug:list", PrivilegeCategoryKeys.Administration),
    ];

    /// <summary>A key's actions hold on the whole server or on named collections; nothing is granted on the database itself.</summary>
    public static PrivilegeCatalog Catalog { get; } = new(Actions, [], [], Actions, []);

    public static IReadOnlyList<TypesenseApiKey> Parse(JsonElement response)
    {
        if (!response.TryGetProperty("keys", out var keys) || keys.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        var parsed = new List<TypesenseApiKey>();
        foreach (var key in keys.EnumerateArray())
        {
            if (!key.TryGetProperty("id", out var id) || !id.TryGetInt64(out var value))
            {
                continue;
            }

            parsed.Add(new TypesenseApiKey(
                value,
                key.TryGetProperty("description", out var description) && description.ValueKind == JsonValueKind.String ? description.GetString()! : string.Empty,
                Strings(key, "actions"),
                Strings(key, "collections")));
        }

        return parsed;
    }

    public static PrincipalInfo Principal(TypesenseApiKey key) => new(new PrincipalRef(key.DisplayName));

    /// <summary>The key id back out of a display name, since a principal carries only its name.</summary>
    public static long? Id(string displayName)
    {
        var hash = displayName.LastIndexOf('#');
        var digits = hash < 0 ? displayName.AsSpan() : displayName.AsSpan(hash + 1).TrimEnd(')');
        return long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var id) ? id : null;
    }

    /// <summary>Every action on every collection the key names; no collections, or <c>*</c>, is the whole server.</summary>
    public static IReadOnlyList<PrincipalGrant> Grants(TypesenseApiKey key)
    {
        IReadOnlyList<PrivilegeScope> scopes = key.Collections.Count == 0 || key.Collections.Contains(AllCollections)
            ? [PrivilegeScope.Server]
            : [.. key.Collections.Select(c => PrivilegeScope.ForTable(DatabaseName, null, c))];
        return [.. key.Actions.SelectMany(action => scopes.Select(scope => new PrincipalGrant(action, scope)))];
    }

    /// <summary>
    /// A new key gets the description it was created with, searching every collection, as on macOS; the grants it holds
    /// cannot be changed afterwards.
    /// </summary>
    public IReadOnlyList<string> CreatePrincipal(PrincipalDefinition definition)
    {
        var body = new JsonObject
        {
            ["actions"] = new JsonArray(DefaultAction),
            ["collections"] = new JsonArray(AllCollections),
            ["description"] = definition.Ref.Name,
        };
        return ["POST /keys\n" + body.ToJsonString()];
    }

    public IReadOnlyList<string>? DropPrincipal(PrincipalRef principal, PrincipalDropOptions options) =>
        Id(principal.Name) is { } id ? [string.Create(CultureInfo.InvariantCulture, $"DELETE /keys/{id}")] : null;

    // Typesense has no endpoint that changes a key; deleting and recreating one would rotate the value every client uses.
    public IReadOnlyList<string>? AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed) => null;

    public IReadOnlyList<string>? SetPassword(PrincipalRef principal, string password) => null;

    public IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => null;

    public IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => null;

    private static PrivilegeDescriptor Action(string name, string category) => new(name, name, category);

    private static string[] Strings(JsonElement key, string property) =>
        key.TryGetProperty(property, out var values) && values.ValueKind == JsonValueKind.Array
            ? [.. values.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!)]
            : [];
}
