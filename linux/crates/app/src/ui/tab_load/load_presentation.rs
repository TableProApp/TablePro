use super::LoadFailure;

/// What a tab shows for where its read stands.
#[derive(Debug, Clone)]
pub(crate) struct LoadPresentation {
    pub page: ContentPage,
    /// The tab's page in the tab bar spins while a read runs.
    pub tab_loading: bool,
    /// The read that failed while the content stayed on screen.
    pub stale: Option<LoadFailure>,
}

#[derive(Debug, Clone)]
pub(crate) enum ContentPage {
    Spinner,
    Content,
    Error(LoadFailure),
}
