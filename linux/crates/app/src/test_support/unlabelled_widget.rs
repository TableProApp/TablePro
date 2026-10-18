use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub(crate) enum UnlabelledWidget {
    #[error("the GTK test accessibility backend is not active; run the tests with GTK_A11Y=test")]
    TestBackendMissing,
    #[error("{type_name} has an empty row title")]
    EmptyRowTitle { type_name: String },
    #[error("the text field inside {type_name} is not labelled by the row title")]
    EntryTextNotLabelled { type_name: String },
    #[error("the activatable widget of {type_name} is not labelled by the row")]
    ActivatableWidgetNotLabelled { type_name: String },
    #[error("{type_name} has no accessible label")]
    MissingLabel { type_name: String },
}
