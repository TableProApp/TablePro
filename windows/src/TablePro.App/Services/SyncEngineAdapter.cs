using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

internal sealed class SyncEngineAdapter(TableProSync sync) : ISyncEngine
{
    public SyncStatus Status => sync.Status;

    public IReadOnlyList<SyncScopeStatus> Scopes => sync.Scopes;

    public string? ServiceAccount => sync.ServiceAccount;

    public IAsyncEnumerable<SyncChanges> ReadChangesAsync(CancellationToken cancellationToken) =>
        sync.ReadChangesAsync(cancellationToken);

    public Task SyncNowAsync(SyncPassReason why) => sync.SyncNowAsync(why);

    public Task SetCategoriesAsync(SyncCategories categories) => sync.SetCategoriesAsync(categories);

    public void SetHistoryWindow(int? entries) => sync.SetHistoryWindow(entries);

    public Task ChooseProviderAsync(SyncProvider provider) => sync.ChooseProviderAsync(provider);

    public Task<SyncUploadPlan> PlanUploadAsync() => sync.PlanUploadAsync();

    public Task<bool?> GetOpenUploadAsync() => sync.GetOpenUploadAsync();

    public Task<KeyState> GetKeyStateAsync() => sync.GetKeyStateAsync();

    public Task<NewIdentityPlan> PlanNewIdentityAsync() => sync.PlanNewIdentityAsync();

    public Task ChooseForNewIdentityAsync(NewIdentityChoice choice, string account) =>
        sync.ChooseForNewIdentityAsync(choice, account);

    public void Dispose() => sync.Dispose();
}
