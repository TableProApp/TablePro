using TablePro.Core.Drivers;
using TablePro.Core.Principals;

namespace TablePro.Drivers.Typesense;

/// <summary>
/// Users and Roles over Typesense API keys, as the macOS app offers it: keys are listed with what they may do, and can
/// be created and deleted. A key is immutable and has no password, so nothing else is editable.
/// </summary>
internal sealed partial class TypesenseSession : IUserAdministration
{
    private static readonly UserAdministrationFeatures TypesenseUserFeatures = new(
        ConnectionLimit: false,
        RoleLogin: false,
        Passwords: false,
        Immutable: true);

    private static readonly TypesenseUserKeys KeyRequests = new();

    public UserAdministrationFeatures? Features => TypesenseUserFeatures;

    public async Task<PrincipalSnapshot> LoadPrincipalsAsync(CancellationToken cancellationToken)
    {
        var keys = await ApiKeysAsync(cancellationToken);
        return new PrincipalSnapshot(
            [.. keys.Select(TypesenseUserKeys.Principal)],
            TypesenseUserKeys.Catalog,
            [TypesenseUserKeys.DatabaseName],
            TypesenseUserKeys.DatabaseName,
            CurrentPrincipal: null);
    }

    public async Task<IReadOnlyList<PrincipalGrant>> LoadGrantsAsync(PrincipalRef principal, CancellationToken cancellationToken)
    {
        if (TypesenseUserKeys.Id(principal.Name) is not { } id)
        {
            return [];
        }

        var key = (await ApiKeysAsync(cancellationToken)).FirstOrDefault(k => k.Id == id);
        return key is null ? [] : TypesenseUserKeys.Grants(key);
    }

    public async Task<IReadOnlyList<PrivilegeScope>> LoadChildScopesAsync(PrivilegeScope scope, CancellationToken cancellationToken)
    {
        if (scope.Level != PrivilegeLevel.Database)
        {
            return [];
        }

        await Yield();
        using var response = await RequestAsync(HttpMethod.Get, "/collections", null, cancellationToken);
        return [.. response.RootElement.EnumerateArray()
            .Select(c => TsCollection.Parse(c).Name)
            .Order(StringComparer.OrdinalIgnoreCase)
            .Select(name => PrivilegeScope.ForTable(TypesenseUserKeys.DatabaseName, null, name))];
    }

    public Task<IReadOnlyList<PrivilegeScope>> SearchScopesAsync(string text, int limit, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<PrivilegeScope>>([]);

    public Task<bool> OwnsObjectsAsync(PrincipalRef principal, CancellationToken cancellationToken) => Task.FromResult(false);

    // A key whose collections are * holds its actions on every collection.
    public bool Cascades(PrivilegeScope ancestor, PrivilegeScope descendant) => ancestor.Level == PrivilegeLevel.Server;

    public IReadOnlyList<PrincipalStatement> BuildStatements(IReadOnlyList<PrincipalChange> changes) => PrincipalScript.Build(KeyRequests, changes);

    private async Task<IReadOnlyList<TypesenseApiKey>> ApiKeysAsync(CancellationToken cancellationToken)
    {
        await Yield();
        using var response = await RequestAsync(HttpMethod.Get, "/keys", null, cancellationToken);
        return TypesenseUserKeys.Parse(response.RootElement);
    }
}
