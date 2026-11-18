using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;

namespace TablePro.App.Views;

// A run that ended out of sight notifies, worded as macOS words it: the connection, its database, the outcome.
public sealed partial class WorkspaceView
{
    private void OnRunEnded(object? sender, RunEnd end)
    {
        if (sender is not QueryTabView query
            || !FinishNotice.Tells(_workbench.Settings, end, FinishNotifications.IsInView(query)))
        {
            return;
        }

        var duration = FinishNotice.Duration(end.Elapsed);
        var body = end switch
        {
            { Failure: { } failure } => Strings.Format("NotifyFailed", duration, failure),
            { Rows: 1 } => Strings.Format("NotifyRow", duration),
            { Rows: { } rows } => Strings.Format("NotifyRows", rows, duration),
            { RowsAffected: 1 } => Strings.Format("NotifyAffectedOne", duration),
            { RowsAffected: { } affected } => Strings.Format("NotifyAffected", affected, duration),
            _ => Strings.Format("NotifyDone", duration),
        };
        var group = _connection.ConnectionId?.ToString("N") ?? _connection.Title;
        FinishNotifications.Post(query, query.NoticeKey, group, _connection.Title, query.ShownDatabase, body);
    }

    // The tab a clicked notification came from comes forward; false when this workspace does not hold it.
    internal bool SelectTab(object content)
    {
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
        {
            if (ReferenceEquals(item.Content, content))
            {
                Tabs.SelectedItem = item;
                return true;
            }
        }

        return false;
    }
}
