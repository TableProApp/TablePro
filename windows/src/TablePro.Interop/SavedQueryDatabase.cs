using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// One store per core: every SavedQueries and Favourites opened from it sees the others' writes.
public sealed class SavedQueryDatabase : IDisposable
{
    private readonly Native.SavedQueryDatabaseStore _store;

    internal SavedQueryDatabase(Native.SavedQueryDatabaseStore store)
    {
        _store = store;
    }

    public SavedQueries OpenSavedQueries() => new(CoreCall.Run(() => _store.SavedQueries()));

    public Favourites OpenFavourites() => new(CoreCall.Run(() => _store.Favourites()));

    public void Dispose() => _store.Dispose();
}
