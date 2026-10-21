use super::{BrowseCellValueRequest, BrowsePageRequest, BrowseRowCountRequest, paste, reference};
use tablepro_core::{ColumnInfo, ForeignKeyInfo, QueryResult, Value};

#[derive(Debug)]
pub enum BrowseTabInput {
    EditsFlushed {
        revision: u64,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    RowsLoaded {
        request: BrowsePageRequest,
        result: QueryResult,
        projected_columns: Option<Vec<usize>>,
    },
    ColumnsLoaded(Vec<ColumnInfo>),
    ForeignKeysLoaded(Vec<ForeignKeyInfo>),
    EnumLabelsLoaded(Vec<(String, Vec<String>)>),
    RowCountLoaded {
        request: BrowseRowCountRequest,
        count: u64,
    },
    RowCountFailed(BrowseRowCountRequest),
    ShowError(String),
    Refresh,
    ClearSelection,
    ToggleFilterStrip,
    FilterApplied(tablepro_core::FilterSet),
    FirstPage,
    PrevPage,
    NextPage,
    LastPage,
    SortChanged {
        col_idx: usize,
        ascending: bool,
    },
    PageSizeChanged(u64),
    InsertRow,
    FocusInsertedDraft,
    DeleteSelectedRow,
    GridCellEdited {
        row_position: u32,
        col_index: usize,
        new_value: String,
        value: Option<Value>,
        row_key: Vec<Value>,
    },
    FilterByValue {
        column: String,
        value: tablepro_core::Value,
    },
    GoToReference {
        column: String,
        row: Vec<(String, Value)>,
    },
    GridSetCellNull {
        row_position: u32,
        col_index: usize,
        row_key: Vec<Value>,
    },
    GridDeleteRowAt {
        row_position: u32,
        row_key: Vec<Value>,
    },
    GridCopyRowAsStatement(u32, tablepro_core::sql_literal::RowStatement),
    DuplicateRow {
        row_position: u32,
    },
    GridCopyToClipboard(String),
    GridFetchCellValue {
        col_index: usize,
        column_name: String,
        row_key: Vec<Value>,
    },
    CellValueLoaded {
        request: BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        value: Value,
    },
    CellValueFailed(BrowseCellValueRequest, String),
    IncompleteRowData,
    ProjectionFailure,
    GridShowRowAsJson(String),
    GridExportResults(QueryResult),
    GridExportStreamedResults(crate::ui::export_dialog::StreamExportRequest),
    Undo,
    Redo,
    CommitSave,
    DiscardAll,
    PendingCountChanged(usize),
    ChangedRows(Vec<crate::services::change_tracker::RowKey>),
    SaveCompleted,
    SaveFailed(String),
    FlashErrorRow(crate::services::change_tracker::StatementSource),
    CopySelectedRowsAsTsv,
    PasteNotSupported,
    Paste(paste::PasteAnchor),
    PasteText(paste::PasteTextInput),
    SelectAllRows,
    GoToFirstRow,
    GoToLastRow,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum BrowseTabOutput {
    OpenReferencedRow {
        schema: Option<String>,
        table: String,
        filter: tablepro_core::FilterSet,
    },
    ChooseReferencedRow(Vec<reference::ReferencedRowTarget>),
    FetchPage,
    FetchColumns,
    FetchRowCount,
    FetchCellValue {
        request: BrowseCellValueRequest,
        col_index: usize,
        column_name: String,
        row_key: Vec<Value>,
    },
    StateChanged,
    CopyRowAsStatement {
        row_position: u32,
        statement: tablepro_core::sql_literal::RowStatement,
    },
    CopyToClipboard(String),
    ShowRowAsJson(String),
    ExportResults {
        result: QueryResult,
        name: String,
    },
    ExportStreamedResults(crate::ui::export_dialog::StreamExportRequest),
    SchemaWordsChanged(Vec<String>),
    ShowSelectionAlert {
        title: String,
        body: String,
    },
    ShowToast(String),
    DirtyChanged(bool),
    ExecuteTransaction {
        statements: Vec<(String, Vec<Value>)>,
        sources: Vec<crate::services::change_tracker::StatementSource>,
    },
}
