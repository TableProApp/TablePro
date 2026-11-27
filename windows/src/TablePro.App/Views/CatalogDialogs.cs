using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The questions before a table is emptied or dropped and a schema or database is made or dropped. Each shows the
// statements its options plan, planned again as they change, and answers with the plan shown.
internal static class CatalogDialogs
{
    private const string MonoFont = "Cascadia Mono, Consolas, Courier New";

    public static Task<CatalogChange?> AskTruncateAsync(
        FrameworkElement owner,
        DatabaseSession session,
        TableName table,
        CatalogAbilities abilities,
        IReadOnlyList<string> clusters)
    {
        var form = new Form(Strings.Format("TruncateTitle", table.Name), Strings.Get("TruncateMessage"), "TruncateAction");
        var cascade = abilities.TruncateCascade ? form.Check("TruncateCascade", "TruncateCascadeDetail", "TruncateCascade") : null;
        var restart = abilities.TruncateRestartIdentity
            ? form.Check("TruncateRestartIdentity", "TruncateRestartIdentityDetail", "TruncateRestartIdentity")
            : null;
        var cluster = form.Cluster(clusters);
        return form.AskAsync(owner, () => session.PlanCatalogChange(new CatalogOperation.TruncateTable(
            table, cascade?.IsChecked == true, restart?.IsChecked == true, Form.Picked(cluster))));
    }

    public static Task<CatalogChange?> AskDropTableAsync(
        FrameworkElement owner,
        DatabaseSession session,
        TableName table,
        CatalogAbilities abilities,
        IReadOnlyList<TableName> referencing)
    {
        var form = new Form(Strings.Format("DropTableTitle", table.Name), Strings.Get("DropTableMessage"), "DropAction");
        var cascade = abilities.DropTableCascade
            ? referencing.Count > 0
                ? form.Check("DropCascade", "DropTableCascadeNamed", "DropCascade", Names(table, referencing))
                : form.Check("DropCascade", "DropTableCascadeDetail", "DropCascade")
            : null;
        return form.AskAsync(owner, () => session.PlanCatalogChange(
            new CatalogOperation.DropTable(table, cascade?.IsChecked == true)));
    }

    public static Task<CatalogChange?> AskDropSchemaAsync(
        FrameworkElement owner,
        DatabaseSession session,
        string schema,
        CatalogAbilities abilities)
    {
        var form = new Form(Strings.Format("DropSchemaTitle", schema), Strings.Get("DropContainerMessage"), "DropAction");
        var cascade = abilities.DropSchemaCascade
            ? form.Check("DropCascade", "DropSchemaCascadeDetail", "DropCascade")
            : null;
        return form.AskAsync(owner, () => session.PlanCatalogChange(
            new CatalogOperation.DropSchema(schema, cascade?.IsChecked == true)));
    }

    public static Task<CatalogChange?> AskDropDatabaseAsync(
        FrameworkElement owner,
        DatabaseSession session,
        string database,
        CatalogAbilities abilities,
        IReadOnlyList<string> clusters)
    {
        var title = Strings.Format(abilities.Keyspaces ? "DropKeyspaceTitle" : "DropDatabaseTitle", database);
        var form = new Form(title, Strings.Get("DropContainerMessage"), "DropAction");
        var force = abilities.DropDatabaseForce
            ? form.Check("DropDatabaseForce", "DropDatabaseForceDetail", "DropDatabaseForce")
            : null;
        var cluster = form.Cluster(clusters);
        return form.AskAsync(owner, () => session.PlanCatalogChange(
            new CatalogOperation.DropDatabase(database, force?.IsChecked == true, Form.Picked(cluster))));
    }

    public static Task<CatalogChange?> AskNewSchemaAsync(
        FrameworkElement owner,
        DatabaseSession session,
        CatalogAbilities abilities,
        NewDatabaseChoices choices)
    {
        var form = new Form(Strings.Get("NewSchemaTitle"), null, "CreateAction");
        var name = form.Name();
        var schemaOwner = abilities.SchemaOwner ? form.Pick("CatalogOwner", "CatalogOwner", choices.Owners, choices.DefaultOwner) : null;
        return form.AskAsync(
            owner,
            () => session.PlanCatalogChange(new CatalogOperation.CreateSchema(name.Text.Trim(), Form.Picked(schemaOwner))),
            () => name.Text.Trim().Length > 0);
    }

    public static Task<CatalogChange?> AskNewDatabaseAsync(
        FrameworkElement owner,
        DatabaseSession session,
        CatalogAbilities abilities,
        NewDatabaseChoices choices)
    {
        var fields = abilities.DatabaseFields;
        var form = new Form(Strings.Get(abilities.Keyspaces ? "NewKeyspaceTitle" : "NewDatabaseTitle"), null, "CreateAction");
        var name = form.Name();
        var databaseOwner = fields.Owner ? form.Pick("CatalogOwner", "CatalogOwner", choices.Owners, choices.DefaultOwner) : null;
        var template = fields.Template ? form.Pick("CatalogTemplate", "CatalogTemplate", choices.Templates, null) : null;
        var encoding = fields.Encoding ? form.Pick("CatalogEncoding", "CatalogEncoding", choices.Encodings, choices.DefaultEncoding) : null;
        var locale = fields.Locale ? form.Pick("CatalogLocale", "CatalogLocale", choices.Locales, choices.DefaultLocale) : null;
        var characterSet = fields.CharacterSet
            ? form.Pick(
                "CatalogCharacterSet",
                "CatalogCharacterSet",
                [.. choices.CharacterSets.Select(set => set.Name)],
                choices.DefaultCharacterSet)
            : null;
        var collation = fields.Collation
            ? form.Pick("CatalogCollation", "CatalogCollation", choices.Collations, choices.DefaultCollation)
            : null;
        if (characterSet is not null && collation is not null)
        {
            // A collation belongs to a character set, so the list follows the one picked.
            characterSet.SelectionChanged += (_, _) =>
            {
                var picked = choices.CharacterSets.FirstOrDefault(set => set.Name == Form.Picked(characterSet));
                Form.Fill(collation, picked?.Collations ?? choices.Collations, picked?.DefaultCollation ?? choices.DefaultCollation);
            };
        }

        var replication = fields.Replication ? form.Replication(choices.DataCenters) : null;
        var durable = fields.Replication ? form.Check("CatalogDurableWrites", "CatalogDurableWritesDetail", "CatalogDurableWrites") : null;
        if (durable is not null)
        {
            durable.IsChecked = true;
        }

        var tablets = fields.Tablets ? form.Pick("CatalogTablets", "CatalogTablets", [Strings.Get("On"), Strings.Get("Off")], null) : null;
        var collection = fields.FirstCollection ? form.Text("CatalogFirstCollection", "CatalogFirstCollection") : null;
        var cluster = abilities.OnCluster ? form.Cluster(choices.Clusters) : null;
        return form.AskAsync(
            owner,
            () => session.PlanCatalogChange(new CatalogOperation.CreateDatabase(new DatabaseDraft(name.Text.Trim())
            {
                Owner = Form.Picked(databaseOwner),
                Template = Form.Picked(template),
                Encoding = Form.Picked(encoding),
                Locale = Form.Picked(locale),
                CharacterSet = Form.Picked(characterSet),
                Collation = Form.Picked(collation),
                Cluster = Form.Picked(cluster),
                Replication = replication?.Chosen(),
                DurableWrites = durable?.IsChecked != false,
                Tablets = tablets?.SelectedIndex switch
                {
                    1 => true,
                    2 => false,
                    _ => null,
                },
                FirstCollection = collection?.Text.Trim(),
            })),
            () => name.Text.Trim().Length > 0 && (collection is null || collection.Text.Trim().Length > 0));
    }

    // A table some other table points at cannot be emptied there; its keys have to go first, as the Linux app says.
    public static async Task ShowRefusedAsync(FrameworkElement owner, string title, string message)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            CloseButtonText = Strings.Get("PreviewSqlDone"),
            DefaultButton = ContentDialogButton.Close,
        };
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
    }

    // The other tables by name, qualified only where their schema is not the table's.
    public static string Names(TableName table, IReadOnlyList<TableName> others) =>
        Strings.List(others.Select(other =>
            other.Schema is { } schema && !string.Equals(schema, table.Schema, StringComparison.Ordinal)
                ? $"{schema}.{other.Name}"
                : other.Name));

    private sealed class Form
    {
        private readonly StackPanel _content = new() { Spacing = 12 };
        private readonly TextBlock _statements = new()
        {
            FontFamily = new FontFamily(MonoFont),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };

        private readonly ContentDialog _dialog;
        private readonly List<Action<Action>> _watches = [];
        private CatalogChange? _planned;

        public Form(string title, string? message, string verb)
        {
            _dialog = new ContentDialog
            {
                Title = title,
                Content = new ScrollViewer { Content = _content, MaxHeight = 480 },
                PrimaryButtonText = Strings.Get(verb),
                CloseButtonText = Strings.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            AutomationProperties.SetAutomationId(_statements, "CatalogStatements");
            if (message is not null)
            {
                _content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
            }
        }

        public static string? Picked(ComboBox? box) =>
            box is { SelectedIndex: > 0, SelectedItem: string value } ? value : null;

        // The first item is the server's own choice, named with its default where the server said it.
        public static void Fill(ComboBox box, IReadOnlyList<string> values, string? fallback)
        {
            box.Items.Clear();
            box.Items.Add(fallback is null ? Strings.Get("CatalogDefault") : Strings.Format("CatalogDefaultNamed", fallback));
            foreach (var value in values)
            {
                box.Items.Add(value);
            }

            box.SelectedIndex = 0;
        }

        public TextBox Name()
        {
            var name = Text("CatalogName", "CatalogName");
            name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
            return name;
        }

        public TextBox Text(string header, string automationId)
        {
            var box = new TextBox { Header = Strings.Get(header) };
            AutomationProperties.SetAutomationId(box, automationId);
            _content.Children.Add(box);
            _watches.Add(refresh => box.TextChanged += (_, _) => refresh());
            return box;
        }

        public CheckBox Check(string title, string detail, string automationId, string? detailValue = null)
        {
            var box = new CheckBox { Content = Strings.Get(title) };
            AutomationProperties.SetAutomationId(box, automationId);
            var panel = new StackPanel { Spacing = 2 };
            panel.Children.Add(box);
            panel.Children.Add(new TextBlock
            {
                Text = detailValue is null ? Strings.Get(detail) : Strings.Format(detail, detailValue),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(28, 0, 0, 0),
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
            _content.Children.Add(panel);
            _watches.Add(refresh =>
            {
                box.Checked += (_, _) => refresh();
                box.Unchecked += (_, _) => refresh();
            });
            return box;
        }

        public ComboBox Pick(string header, string automationId, IReadOnlyList<string> values, string? fallback)
        {
            var box = new ComboBox { Header = Strings.Get(header), HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(box, automationId);
            Fill(box, values, fallback);
            _content.Children.Add(box);
            _watches.Add(refresh => box.SelectionChanged += (_, _) => refresh());
            return box;
        }

        // Only a server in a cluster of more than itself offers one; the first item runs on this server only.
        public ComboBox? Cluster(IReadOnlyList<string> clusters)
        {
            if (clusters.Count == 0)
            {
                return null;
            }

            var box = Pick("CatalogCluster", "CatalogCluster", clusters, null);
            box.Items[0] = Strings.Get("CatalogClusterNone");
            box.SelectedIndex = 0;
            return box;
        }

        public ReplicationRows Replication(IReadOnlyList<string> dataCenters)
        {
            var rows = new ReplicationRows(dataCenters);
            _content.Children.Add(rows.Root);
            _watches.Add(rows.Watch);
            return rows;
        }

        // Null when cancelled; ready says whether the fields typed so far can plan at all.
        public async Task<CatalogChange?> AskAsync(FrameworkElement owner, Func<CatalogChange> plan, Func<bool>? ready = null)
        {
            _content.Children.Add(_statements);
            _dialog.RequestedTheme = owner.ActualTheme;
            void Refresh()
            {
                _planned?.Dispose();
                _planned = null;
                if (ready is not null && !ready())
                {
                    _statements.Text = string.Empty;
                    _dialog.IsPrimaryButtonEnabled = false;
                    return;
                }

                try
                {
                    var next = plan();
                    _planned = next;
                    _statements.Text = string.Join("\n\n", next.Statements.Select(statement => statement + ";"));
                    _dialog.IsPrimaryButtonEnabled = next.Gate != SaveGate.Refuse;
                }
                catch (TableProException exception)
                {
                    _statements.Text = Strings.Error(exception.Error);
                    _dialog.IsPrimaryButtonEnabled = false;
                }
                catch (ObjectDisposedException)
                {
                    // The window let go of its session while the question was open.
                    _statements.Text = string.Empty;
                    _dialog.IsPrimaryButtonEnabled = false;
                }
            }

            foreach (var watch in _watches)
            {
                watch(Refresh);
            }

            Refresh();
            var answer = await WindowDialogs.ShowAsync(_dialog, owner).ConfigureAwait(true);
            var planned = _planned;
            _planned = null;
            if (answer == ContentDialogResult.Primary && planned is not null)
            {
                return planned;
            }

            planned?.Dispose();
            return null;
        }
    }

    // A keyspace's replication: one factor for the whole cluster, or replicas per data centre.
    private sealed class ReplicationRows
    {
        private readonly ComboBox _strategy = new() { Header = Strings.Get("CatalogReplication"), HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly NumberBox _factor = Replicas(Strings.Get("CatalogReplicationFactor"), 1, 1);
        private readonly List<(string DataCenter, NumberBox Box)> _centres = [];
        private readonly StackPanel _perCentre = new() { Spacing = 8 };

        public ReplicationRows(IReadOnlyList<string> dataCenters)
        {
            AutomationProperties.SetAutomationId(_strategy, "CatalogReplication");
            _strategy.Items.Add(Strings.Get("CatalogReplicationSimple"));
            foreach (var centre in dataCenters)
            {
                var box = Replicas(Strings.Format("CatalogReplicasIn", centre), 0, 1);
                _centres.Add((centre, box));
                _perCentre.Children.Add(box);
            }

            if (_centres.Count > 0)
            {
                _strategy.Items.Add(Strings.Get("CatalogReplicationTopology"));
            }

            _strategy.SelectedIndex = _centres.Count > 0 ? 1 : 0;
            Root.Children.Add(_strategy);
            Root.Children.Add(_factor);
            Root.Children.Add(_perCentre);
            Show();
            _strategy.SelectionChanged += (_, _) => Show();
        }

        public StackPanel Root { get; } = new() { Spacing = 8 };

        private bool Simple => _strategy.SelectedIndex <= 0;

        public KeyspaceReplication Chosen() => Simple
            ? new KeyspaceReplication.Simple(Count(_factor))
            : new KeyspaceReplication.NetworkTopology(
                [.. _centres
                    .Select(centre => new DataCenterReplicas(centre.DataCenter, Count(centre.Box)))
                    .Where(centre => centre.Replicas > 0)]);

        public void Watch(Action refresh)
        {
            _strategy.SelectionChanged += (_, _) => refresh();
            _factor.ValueChanged += (_, _) => refresh();
            foreach (var (_, box) in _centres)
            {
                box.ValueChanged += (_, _) => refresh();
            }
        }

        private static NumberBox Replicas(string header, double least, double value) => new()
        {
            Header = header,
            Minimum = least,
            Maximum = 100,
            Value = value,
            SmallChange = 1,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
        };

        private static int Count(NumberBox box) => double.IsNaN(box.Value) ? 0 : (int)Math.Round(box.Value);

        private void Show()
        {
            _factor.Visibility = Simple ? Visibility.Visible : Visibility.Collapsed;
            _perCentre.Visibility = Simple ? Visibility.Collapsed : Visibility.Visible;
        }
    }
}
