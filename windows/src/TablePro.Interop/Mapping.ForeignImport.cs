using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static ForeignApp ForeignApp(Native.ForeignAppTag app) => app switch
    {
        Native.ForeignAppTag.TablePlus => Interop.ForeignApp.TablePlus,
        Native.ForeignAppTag.SequelAce => Interop.ForeignApp.SequelAce,
        Native.ForeignAppTag.DBeaver => Interop.ForeignApp.DBeaver,
        Native.ForeignAppTag.DataGrip => Interop.ForeignApp.DataGrip,
        Native.ForeignAppTag.BeekeeperStudio => Interop.ForeignApp.BeekeeperStudio,
        Native.ForeignAppTag.Navicat => Interop.ForeignApp.Navicat,
        _ => Interop.ForeignApp.Dbx,
    };

    public static Native.ForeignAppTag ForeignApp(ForeignApp app) => app switch
    {
        Interop.ForeignApp.TablePlus => Native.ForeignAppTag.TablePlus,
        Interop.ForeignApp.SequelAce => Native.ForeignAppTag.SequelAce,
        Interop.ForeignApp.DBeaver => Native.ForeignAppTag.DBeaver,
        Interop.ForeignApp.DataGrip => Native.ForeignAppTag.DataGrip,
        Interop.ForeignApp.BeekeeperStudio => Native.ForeignAppTag.BeekeeperStudio,
        Interop.ForeignApp.Navicat => Native.ForeignAppTag.Navicat,
        _ => Native.ForeignAppTag.Dbx,
    };

    public static Native.ForeignAppDirsArg Dirs(ForeignAppDirs dirs) => new(dirs.Home, dirs.Config, dirs.Data);

    public static ForeignSource Source(Native.ForeignSourceInfo source) => new(
        ForeignApp(source.App),
        source.Name,
        source.Available,
        Count(source.Connections),
        Count(source.SavedQueries),
        [.. source.FileExtensions],
        source.Passwords == Native.PasswordSourceTag.AppFiles
            ? ForeignPasswordSource.AppFiles
            : ForeignPasswordSource.Keychain,
        source.SavedQuerySupport switch
        {
            Native.SavedQuerySupportTag.GlobalFolder => ForeignSavedQuerySupport.GlobalFolder,
            Native.SavedQuerySupportTag.Scripts => ForeignSavedQuerySupport.Scripts,
            Native.SavedQuerySupportTag.Consoles => ForeignSavedQuerySupport.Consoles,
            _ => ForeignSavedQuerySupport.NotInExport,
        });

    public static ForeignPasswordOutcome Outcome(Native.PasswordOutcomeTag outcome) => outcome switch
    {
        Native.PasswordOutcomeTag.NotRequested => ForeignPasswordOutcome.NotRequested,
        Native.PasswordOutcomeTag.Read => ForeignPasswordOutcome.Read,
        Native.PasswordOutcomeTag.Stopped => ForeignPasswordOutcome.Stopped,
        _ => ForeignPasswordOutcome.LeftBehind,
    };

    public static ForeignConnectionRow ForeignRow(Native.ForeignConnectionRow row) => new(
        row.Reference,
        row.Name,
        row.Engine,
        row.Connection is { } connection ? Connection(connection) : null,
        [.. row.GroupPath],
        row.Duplicate is { } duplicate ? new ExistingConnection(Guid.Parse(duplicate.Id), duplicate.Name) : null,
        [.. row.Notes.Select(Note)],
        checked((int)row.SavedQueryCount),
        row.CarriesPasswords);

    public static ForeignResolution Resolution(Native.ResolutionTag resolution) => resolution switch
    {
        Native.ResolutionTag.Replace replace => new ForeignResolution.Replace(Guid.Parse(replace.Id)),
        Native.ResolutionTag.KeepExisting keep => new ForeignResolution.KeepExisting(Guid.Parse(keep.Id)),
        Native.ResolutionTag.AddCopy => ForeignResolution.AddCopy.Instance,
        _ => ForeignResolution.Add.Instance,
    };

    public static Native.ResolutionTag Resolution(ForeignResolution resolution) => resolution switch
    {
        ForeignResolution.Replace replace => new Native.ResolutionTag.Replace(replace.Id.ToString()),
        ForeignResolution.KeepExisting keep => new Native.ResolutionTag.KeepExisting(keep.Id.ToString()),
        ForeignResolution.AddCopy => new Native.ResolutionTag.AddCopy(),
        _ => new Native.ResolutionTag.Add(),
    };

    public static ForeignQueryAvailability Availability(Native.QueryAvailabilityTag availability) => availability switch
    {
        Native.QueryAvailabilityTag.Available => ForeignQueryAvailability.Available,
        Native.QueryAvailabilityTag.AddedByAnotherRow => ForeignQueryAvailability.AddedByAnotherRow,
        Native.QueryAvailabilityTag.TooLarge => ForeignQueryAvailability.TooLarge,
        Native.QueryAvailabilityTag.NameTooLong => ForeignQueryAvailability.NameTooLong,
        Native.QueryAvailabilityTag.ConnectionSkipped => ForeignQueryAvailability.ConnectionSkipped,
        _ => ForeignQueryAvailability.NoConnection,
    };

    private static ForeignRowNote Note(Native.RowNoteInfo note) => note switch
    {
        Native.RowNoteInfo.UnsupportedEngine unsupported => new ForeignRowNote.UnsupportedEngine(unsupported.Engine),
        Native.RowNoteInfo.SshKeyMissing missing => new ForeignRowNote.SshKeyMissing(missing.Path),
        Native.RowNoteInfo.JumpHostKeyMissing missing => new ForeignRowNote.JumpHostKeyMissing(missing.Path),
        Native.RowNoteInfo.CaCertificateMissing missing => new ForeignRowNote.CaCertificateMissing(missing.Path),
        Native.RowNoteInfo.ClientCertificateMissing missing =>
            new ForeignRowNote.ClientCertificateMissing(missing.Path),
        Native.RowNoteInfo.ClientKeyMissing missing => new ForeignRowNote.ClientKeyMissing(missing.Path),
        Native.RowNoteInfo.TlsModeChanged changed =>
            new ForeignRowNote.TlsModeChanged(SslMode(changed.From), Tls(changed.To)),
        Native.RowNoteInfo.TlsSettingsNotRead => new ForeignRowNote.TlsSettingsNotRead(),
        Native.RowNoteInfo.TlsFromDriverDefault from => new ForeignRowNote.TlsFromDriverDefault(SslMode(from.Mode)),
        Native.RowNoteInfo.TlsNotKept dropped => new ForeignRowNote.TlsNotKept(SslMode(dropped.From)),
        Native.RowNoteInfo.CaFileNotKept dropped =>
            new ForeignRowNote.CaFileNotKept(dropped.Path, FileReason(dropped.Reason)),
        Native.RowNoteInfo.ClientIdentityNotKept dropped =>
            new ForeignRowNote.ClientIdentityNotKept(FileReason(dropped.Reason)),
        Native.RowNoteInfo.SshNotKept => new ForeignRowNote.SshNotKept(),
        Native.RowNoteInfo.SshKeyNotKept dropped => new ForeignRowNote.SshKeyNotKept(dropped.Path),
        Native.RowNoteInfo.JumpHostNotKept dropped => new ForeignRowNote.JumpHostNotKept(dropped.Host),
        Native.RowNoteInfo.JumpHostPasswordNotKept dropped => new ForeignRowNote.JumpHostPasswordNotKept(dropped.Host),
        Native.RowNoteInfo.JumpHostKeyNotKept dropped =>
            new ForeignRowNote.JumpHostKeyNotKept(dropped.Host, dropped.Path),
        Native.RowNoteInfo.FieldsNotKept dropped => new ForeignRowNote.FieldsNotKept([.. dropped.Fields]),
        _ => throw new InvalidOperationException("The core reported a note this build does not know."),
    };

    private static ForeignSslMode SslMode(Native.ForeignSslModeTag mode) => mode switch
    {
        Native.ForeignSslModeTag.Disabled => ForeignSslMode.Disabled,
        Native.ForeignSslModeTag.Preferred => ForeignSslMode.Preferred,
        Native.ForeignSslModeTag.Required => ForeignSslMode.Required,
        Native.ForeignSslModeTag.VerifyCa => ForeignSslMode.VerifyCa,
        _ => ForeignSslMode.VerifyIdentity,
    };

    private static TlsFileReason FileReason(Native.TlsFileReasonTag reason) => reason switch
    {
        Native.TlsFileReasonTag.EngineLacks => TlsFileReason.EngineLacks,
        Native.TlsFileReasonTag.ModeLacks => TlsFileReason.ModeLacks,
        Native.TlsFileReasonTag.RelativePath => TlsFileReason.RelativePath,
        _ => TlsFileReason.Incomplete,
    };
}
