using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// An object's definition, read only; the read and the close are DefinitionTab's, so Run and Stop do nothing here.
public sealed partial class DefinitionTabView : UserControl, ITabContent, IDefinitionTabView
{
    private readonly DefinitionTab _model;

    internal DefinitionTabView(SessionShare<DatabaseSession> share, ObjectEntry entry)
    {
        InitializeComponent();
        _model = new DefinitionTab(new CoreTabSession(share), this, entry);
        _model.StateChanged += (_, _) => StateChanged?.Invoke(this, EventArgs.Empty);
        Title = ObjectFolders.HasDefinition(entry.Kind) ? Strings.Format("DefinitionTitle_" + entry.Kind, entry.Name) : entry.Name;
        HeaderText.Text = Title;
    }

    public event EventHandler? StateChanged;

    // The workspace holding the tab opens a query tab with the text.
    public event EventHandler<ObjectSource>? OpenInEditorRequested;

    public string Title { get; }

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

    public SqlEditor? Editor => null;

    public DataGridView? Grid => null;

    public bool GridIsTarget => false;

    public TextBox? MessagesTarget => DefinitionText.Visibility == Visibility.Visible ? DefinitionText : null;

    public bool Shows(ObjectEntry entry) => _model.Entry == entry;

    public async void Load() => await _model.LoadAsync().ConfigureAwait(true);

    public void Run()
    {
    }

    public void Stop()
    {
    }

    // A definition shows source, never rows.
    public void Remask()
    {
    }

    public void FocusContent()
    {
        if (DefinitionText.Visibility == Visibility.Visible)
        {
            DefinitionText.Focus(FocusState.Programmatic);
        }
        else if (UnavailablePanel.Visibility == Visibility.Visible)
        {
            TryAgainButton.Focus(FocusState.Programmatic);
        }
    }

    public SessionTab Snapshot() => _model.Snapshot();

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

    // A reload keeps the text it read last on screen until the new one arrives.
    void IDefinitionTabView.ShowLoading()
    {
        ReloadButton.IsEnabled = false;
        TryAgainButton.IsEnabled = false;
        if (DefinitionText.Visibility == Visibility.Visible)
        {
            return;
        }

        UnavailablePanel.Visibility = Visibility.Collapsed;
        LoadingRing.IsActive = true;
    }

    void IDefinitionTabView.ShowSource(ObjectSource source)
    {
        LoadingRing.IsActive = false;
        UnavailablePanel.Visibility = Visibility.Collapsed;
        DefinitionText.Text = source.Sql;
        DefinitionText.Visibility = Visibility.Visible;
        CopyDefinitionButton.IsEnabled = true;
        OpenInEditorButton.IsEnabled = source.OpensInEditor;
        OpenInEditorButton.Visibility = source.OpensInEditor ? Visibility.Visible : Visibility.Collapsed;
        ShowRefusal(!source.OpensInEditor);
        ReloadButton.IsEnabled = true;
        TryAgainButton.IsEnabled = true;
    }

    // Null: the object is gone, or the login cannot read its definition.
    void IDefinitionTabView.ShowUnavailable(CoreError? failure)
    {
        LoadingRing.IsActive = false;
        DefinitionText.Visibility = Visibility.Collapsed;
        DefinitionText.Text = string.Empty;
        UnavailableText.Text = failure is null ? Strings.Get("SourceUnavailableGone") : Strings.Error(failure);
        UnavailablePanel.Visibility = Visibility.Visible;
        CopyDefinitionButton.IsEnabled = false;
        OpenInEditorButton.IsEnabled = false;
        OpenInEditorButton.Visibility = Visibility.Visible;
        ShowRefusal(false);
        ReloadButton.IsEnabled = true;
        TryAgainButton.IsEnabled = true;
    }

    private void ShowRefusal(bool show)
    {
        // A closed InfoBar keeps its margin, so the bar is collapsed while it is closed.
        EditorRefusalBar.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        EditorRefusalBar.IsOpen = show;
    }

    private void OnOpenInEditor(object sender, RoutedEventArgs e)
    {
        if (_model.Source is { OpensInEditor: true } source)
        {
            OpenInEditorRequested?.Invoke(this, source);
        }
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (_model.Source is { } source)
        {
            WorkspaceView.CopyText(source.Sql);
        }
    }

    private async void OnReload(object sender, RoutedEventArgs e) => await _model.LoadAsync().ConfigureAwait(true);
}
