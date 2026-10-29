using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Export;
using TablePro.Core.Schema;

namespace TablePro.App.Services;

/// <summary>
/// Writes a schema to a SQL file: each table's CREATE, then its rows as batched INSERTs read page by page, then
/// views, so a view is created after the tables it reads.
/// </summary>
public static class DatabaseDumper
{
    private const int PageSize = 5000;

    public static async Task<int> DumpAsync(ConnectionSession session, string path, bool includeData, IProgress<string> progress, CancellationToken cancellationToken)
    {
        var objects = session.Objects.Where(o => o.Kind is ObjectKind.Table or ObjectKind.View or ObjectKind.MaterializedView)
            .OrderBy(o => o.Kind == ObjectKind.Table ? 0 : 1)
            .ThenBy(o => o.Name.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        await using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true);
        await using var writer = new StreamWriter(stream, new UTF8Encoding(false));
        var separator = session.Dialect.BatchSeparator is { } go ? $"\n{go}\n" : "\n";
        await writer.WriteLineAsync($"-- TablePro export of {session.Profile.Name} ({session.Profile.Descriptor.DisplayName} {session.Database.ServerVersion})");
        await writer.WriteLineAsync($"-- {DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}");
        await writer.WriteLineAsync();

        foreach (var obj in objects)
        {
            cancellationToken.ThrowIfCancellationRequested();
            progress.Report(Strings.Format("Workspace/DumpExporting", obj.Name.Name));
            var definition = (await session.Database.GetDefinitionAsync(obj, cancellationToken)).TrimEnd();
            await writer.WriteLineAsync($"-- {obj.Kind} {obj.Name}");
            await writer.WriteAsync(definition);
            await writer.WriteLineAsync(definition.EndsWith(';') ? string.Empty : ";");
            await writer.WriteAsync(separator);

            if (!includeData || obj.Kind != ObjectKind.Table)
            {
                continue;
            }

            for (var offset = 0; ; offset += PageSize)
            {
                var page = await session.Database.BrowseAsync(new BrowseRequest(obj.Name, BrowseFilter.None, [], offset, PageSize), cancellationToken);
                if (page.RowCount == 0)
                {
                    break;
                }

                await writer.FlushAsync(cancellationToken);
                await ResultExporter.WriteAsync(page, null, stream, new ExportOptions(ExportFormat.SqlInsert, TargetTable: obj.Name, Dialect: session.Dialect), cancellationToken);
                if (page.RowCount < PageSize)
                {
                    break;
                }
            }

            await writer.WriteAsync(separator);
        }

        await writer.FlushAsync(cancellationToken);
        return objects.Length;
    }
}
