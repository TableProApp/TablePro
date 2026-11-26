// The Mac's synced categories (`AppSettingsCategory`), with every option as the Mac encodes it. Option names keep the
// Mac's spelling: a settings record is one platform's, and its options cross to another only through a shared entry.

use crate::schema::Approval::{Always, Looser, WhenHigher, WhenOn};
use crate::schema::Class::{Approval, Inert};
use crate::schema::Role::Content;
use crate::schema::{AI_POLICIES, Field, Type};

use super::CategoryId::{ColumnLayout, Named, Theme};
use super::Merge::{ByOption, Whole};
use super::{Category, Document};

const fn option(key: &'static str, ty: Type) -> Field {
    Field {
        key,
        ty,
        class: Inert,
        role: Content,
    }
}

const fn asked(key: &'static str, ty: Type, approval: crate::schema::Approval) -> Field {
    Field {
        key,
        ty,
        class: Approval(approval),
        role: Content,
    }
}

const TEXT: Type = Type::Text;
const INTEGER: Type = Type::Integer;
const BOOL: Type = Type::Boolean;
const NUMBER: Type = Type::Number;

const GENERAL: &[Field] = &[
    option("startupBehavior", TEXT),
    option("language", TEXT),
    option("queryTimeoutSeconds", INTEGER),
    // Usage data leaves the device once it is on.
    asked("shareAnalytics", BOOL, WhenOn),
    option("showRecentTables", BOOL),
    option("showObjectComments", BOOL),
    option("showObjectIcons", BOOL),
    option("showSystemContainers", BOOL),
    option("showPartitions", BOOL),
    option("showWorkspaceRail", BOOL),
    option("sidebarRowSize", TEXT),
    option("connectionHealthCheck", INTEGER),
];

const APPEARANCE: &[Field] = &[
    option("preferredLightThemeId", TEXT),
    option("preferredDarkThemeId", TEXT),
];

const EDITOR: &[Field] = &[
    option("showLineNumbers", BOOL),
    option("highlightCurrentLine", BOOL),
    option("tabWidth", INTEGER),
    option("wordWrap", BOOL),
    option("keyBindings", TEXT),
    option("vimModeEnabled", BOOL),
    option("keywordCase", TEXT),
    option("uppercaseKeywords", BOOL),
    option("queryParametersEnabled", BOOL),
    option("codeFoldingEnabled", BOOL),
    option("highlightCurrentStatement", BOOL),
    option("showStatementRunControls", BOOL),
    option("showInvisibleCharacters", BOOL),
    option("jsonViewerPreferredMode", TEXT),
];

const DATA_GRID: &[Field] = &[
    option("rowHeight", INTEGER),
    option("dateFormat", TEXT),
    option("nullDisplay", TEXT),
    option("defaultPageSize", INTEGER),
    option("showAlternateRows", BOOL),
    option("showRowNumbers", BOOL),
    option("autoShowInspector", BOOL),
    option("enableSmartValueDetection", BOOL),
    option("countRowsIfEstimateLessThan", INTEGER),
    option("queryResultRowCap", INTEGER),
    option("truncateQueryResults", BOOL),
    option("defaultSortBehavior", TEXT),
    option("defaultSortDirection", TEXT),
    option("rowCopyFormat", TEXT),
    option("showInvisibleCharacters", BOOL),
    option("wrapText", BOOL),
    option("resultSetsKeptPerRun", INTEGER),
];

const HISTORY: &[Field] = &[
    option("maxEntries", INTEGER),
    option("maxDays", INTEGER),
    option("autoCleanup", BOOL),
    option("keepRewindHistory", BOOL),
];

const TABS: &[Field] = &[option("enablePreviewTabs", BOOL)];

const NOTIFICATIONS: &[Field] = &[option("isEnabled", BOOL), option("thresholdSeconds", INTEGER)];

const FORMATTER: &[Field] = &[
    option("indentStyle", TEXT),
    option("indentWidth", INTEGER),
    option("keywordCase", TEXT),
    option("functionCase", TEXT),
    option("dataTypeCase", TEXT),
    option("commaPosition", TEXT),
    option("lineWidth", INTEGER),
    option("joinCondition", TEXT),
    option("alignAliases", BOOL),
    option("clauseItems", TEXT),
    option("logicalOperatorNewline", TEXT),
    option("indentFollowsTabWidth", BOOL),
    option("keywordCaseFollowsEditor", BOOL),
];

const VALUE_COLORS: &[Field] = &[option("colorsValuesByType", BOOL)];

const BOUND_KEY: &[Field] = &[
    option("keyCode", INTEGER),
    option("command", BOOL),
    option("shift", BOOL),
    option("option", BOOL),
    option("control", BOOL),
];

// Overrides only, by `ShortcutAction` name.
const KEYBOARD: &[Field] = &[option("shortcuts", Type::Entries(&Type::Object(BOUND_KEY)))];

const AI_PROVIDER: &[Field] = &[
    option("id", TEXT),
    // The provider's type and endpoint are its key's destination (0056, Envelopes and history).
    asked("type", TEXT, Always),
    option("name", TEXT),
    option("presetID", TEXT),
    option("model", TEXT),
    asked("endpoint", TEXT, Always),
    option("maxOutputTokens", INTEGER),
    asked("telemetryEnabled", BOOL, WhenOn),
    option("reasoningEffort", TEXT),
];

const CHAT_MODES: &[&str] = &["ask", "edit", "agent"];

// 0044 names `includeSchema`, `includeQueryResults` and `defaultConnectionPolicy`; every other option that sends a
// provider more, or lets it act, waits the same way.
const AI: &[Field] = &[
    asked("enabled", BOOL, WhenOn),
    asked("providers", Type::List(&Type::Object(AI_PROVIDER)), Always),
    asked("activeProviderID", TEXT, Always),
    asked("inlineSuggestionsEnabled", BOOL, WhenOn),
    option("inlineSuggestionDebounceMs", INTEGER),
    asked("useAppleIntelligence", BOOL, WhenOn),
    asked("includeSchema", BOOL, WhenOn),
    asked("includeCurrentQuery", BOOL, WhenOn),
    asked("includeQueryResults", BOOL, WhenOn),
    asked("maxSchemaTables", INTEGER, WhenHigher),
    asked("maxToolRoundtrips", INTEGER, WhenHigher),
    asked("maxToolRoundtripsEnabled", BOOL, Always),
    asked("defaultConnectionPolicy", TEXT, Looser(AI_POLICIES)),
    asked("chatMode", TEXT, Looser(CHAT_MODES)),
    option("composerHighlightEnabled", BOOL),
];

const SLASH_COMMAND: &[Field] = &[
    option("id", TEXT),
    option("name", TEXT),
    option("description", TEXT),
    option("promptTemplate", TEXT),
];

const COLOR: Type = Type::Text;

const WINDOW_COLORS: &[Field] = &[option("background", COLOR)];

const SYNTAX_COLORS: &[Field] = &[
    option("keyword", COLOR),
    option("string", COLOR),
    option("number", COLOR),
    option("comment", COLOR),
    option("null", COLOR),
    option("operator", COLOR),
    option("function", COLOR),
    option("type", COLOR),
];

const EDITOR_COLORS: &[Field] = &[
    option("background", COLOR),
    option("text", COLOR),
    option("cursor", COLOR),
    option("selection", COLOR),
    option("currentLine", COLOR),
    option("currentStatement", COLOR),
    option("lineNumber", COLOR),
    option("invisibles", COLOR),
    option("syntax", Type::Object(SYNTAX_COLORS)),
];

const DATA_GRID_COLORS: &[Field] = &[
    option("background", COLOR),
    option("text", COLOR),
    option("alternateRow", COLOR),
    option("headerBackground", COLOR),
    option("headerText", COLOR),
    option("gridLine", COLOR),
    option("selection", COLOR),
    option("selectionText", COLOR),
    option("inactiveSelection", COLOR),
    option("focusBorder", COLOR),
    option("nullValue", COLOR),
    option("boolTrue", COLOR),
    option("boolFalse", COLOR),
    option("string", COLOR),
    option("number", COLOR),
    option("dateTime", COLOR),
    option("binary", COLOR),
    option("json", COLOR),
    option("uuid", COLOR),
    option("enum", COLOR),
    option("rowNumber", COLOR),
    option("modified", COLOR),
    option("inserted", COLOR),
    option("deleted", COLOR),
    option("deletedText", COLOR),
];

const THEME: &[Field] = &[
    option("schema", INTEGER),
    option("id", TEXT),
    option("name", TEXT),
    option("author", TEXT),
    option("appearance", TEXT),
    option("window", Type::Object(WINDOW_COLORS)),
    option("editor", Type::Object(EDITOR_COLORS)),
    option("dataGrid", Type::Object(DATA_GRID_COLORS)),
];

// Column names are data, so widths go as entries by column.
const COLUMN_LAYOUT: &[Field] = &[
    option("columnWidths", Type::Entries(&NUMBER)),
    option("columnContentWidths", Type::Entries(&NUMBER)),
    option("columnOrder", Type::List(&TEXT)),
    option("hiddenColumns", Type::List(&TEXT)),
    option("frozenColumnCount", INTEGER),
];

const fn named(name: &'static str, merge: super::Merge, options: &'static [Field]) -> Category {
    Category {
        id: Named(name),
        merge,
        document: Document::Object(options),
    }
}

pub const CATEGORIES: &[Category] = &[
    named("general", ByOption, GENERAL),
    named("appearance", ByOption, APPEARANCE),
    named("editor", ByOption, EDITOR),
    named("dataGrid", ByOption, DATA_GRID),
    named("history", ByOption, HISTORY),
    named("tabs", ByOption, TABS),
    named("keyboard", Whole, KEYBOARD),
    named("ai", Whole, AI),
    named("notifications", ByOption, NOTIFICATIONS),
    named("formatter", ByOption, FORMATTER),
    named("valueColors", ByOption, VALUE_COLORS),
    Category {
        id: Named("customSlashCommands"),
        merge: ByOption,
        document: Document::List(SLASH_COMMAND),
    },
    Category {
        id: Theme,
        merge: Whole,
        document: Document::Object(THEME),
    },
    Category {
        id: ColumnLayout,
        merge: ByOption,
        document: Document::Object(COLUMN_LAYOUT),
    },
];
