use super::{ContentPage, LoadFailure, LoadPresentation};

/// Where a tab's read of its content stands.
///
/// Content on screen stays there while it is read again, and stays when
/// that read fails, under a banner until a read lands. Only a tab with
/// nothing to show shows the spinner or the error page.
#[derive(Debug, Clone, Default)]
pub(crate) enum ContentLoad {
    #[default]
    Initial,
    Loading,
    Loaded,
    /// Reading the content on screen again. `stale` is the failure the
    /// banner keeps showing until this read lands.
    Refreshing {
        stale: Option<LoadFailure>,
    },
    /// Reading other content than the one on screen, which stays until
    /// the new content lands but is not kept if the read fails: it is no
    /// longer what the tab was asked for.
    Replacing,
    Stale(LoadFailure),
    Failed(LoadFailure),
}

impl ContentLoad {
    /// A read of the content on screen, or of the first content.
    pub(crate) fn begin(&mut self) -> LoadPresentation {
        *self = match std::mem::take(self) {
            Self::Initial | Self::Loading | Self::Failed(_) => Self::Loading,
            Self::Loaded => Self::Refreshing { stale: None },
            Self::Stale(failure) => Self::Refreshing { stale: Some(failure) },
            running @ (Self::Refreshing { .. } | Self::Replacing) => running,
        };
        self.presentation()
    }

    /// A read of other content than the one on screen: another page, or
    /// the same table under another filter.
    pub(crate) fn begin_replacing(&mut self) -> LoadPresentation {
        *self = match std::mem::take(self) {
            Self::Initial | Self::Loading | Self::Failed(_) => Self::Loading,
            Self::Loaded | Self::Stale(_) | Self::Refreshing { .. } | Self::Replacing => Self::Replacing,
        };
        self.presentation()
    }

    pub(crate) fn succeed(&mut self) -> LoadPresentation {
        *self = Self::Loaded;
        self.presentation()
    }

    pub(crate) fn fail(&mut self, failure: LoadFailure) -> LoadPresentation {
        *self = match std::mem::take(self) {
            Self::Loaded | Self::Stale(_) | Self::Refreshing { .. } => Self::Stale(failure),
            Self::Initial | Self::Loading | Self::Replacing | Self::Failed(_) => Self::Failed(failure),
        };
        self.presentation()
    }

    /// The read stopped before it asked for anything, so what was on
    /// screen before it stands as it was.
    pub(crate) fn abandon(&mut self) -> LoadPresentation {
        *self = match std::mem::take(self) {
            Self::Loading => Self::Initial,
            Self::Refreshing { stale: None } | Self::Replacing => Self::Loaded,
            Self::Refreshing { stale: Some(failure) } => Self::Stale(failure),
            settled => settled,
        };
        self.presentation()
    }

    /// The content on screen no longer fits what the tab reads, so the
    /// read running goes on with nothing shown.
    pub(crate) fn drop_content(&mut self) -> LoadPresentation {
        *self = match std::mem::take(self) {
            Self::Loading | Self::Refreshing { .. } | Self::Replacing => Self::Loading,
            Self::Loaded | Self::Stale(_) => Self::Initial,
            settled => settled,
        };
        self.presentation()
    }

    pub(crate) fn has_content(&self) -> bool {
        matches!(
            self,
            Self::Loaded | Self::Refreshing { .. } | Self::Replacing | Self::Stale(_)
        )
    }

    pub(crate) fn is_running(&self) -> bool {
        matches!(self, Self::Loading | Self::Refreshing { .. } | Self::Replacing)
    }

    pub(crate) fn presentation(&self) -> LoadPresentation {
        let (page, stale) = match self {
            Self::Initial | Self::Loading => (ContentPage::Spinner, None),
            Self::Loaded | Self::Replacing => (ContentPage::Content, None),
            Self::Refreshing { stale } => (ContentPage::Content, stale.clone()),
            Self::Stale(failure) => (ContentPage::Content, Some(failure.clone())),
            Self::Failed(failure) => (ContentPage::Error(failure.clone()), None),
        };
        LoadPresentation {
            page,
            tab_loading: self.is_running(),
            stale,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq)]
    enum Shown {
        Spinner,
        Content,
        Error,
    }

    /// The page, whether the tab spins, and whether the banner shows.
    fn shown(presentation: &LoadPresentation) -> (Shown, bool, bool) {
        let page = match presentation.page {
            ContentPage::Spinner => Shown::Spinner,
            ContentPage::Content => Shown::Content,
            ContentPage::Error(_) => Shown::Error,
        };
        (page, presentation.tab_loading, presentation.stale.is_some())
    }

    type Step = fn(&mut ContentLoad) -> LoadPresentation;
    /// The steps from a new tab, and the page, spinner and banner after.
    type Case = (&'static [Step], (Shown, bool, bool));

    fn after(steps: &[Step]) -> (ContentLoad, LoadPresentation) {
        let mut load = ContentLoad::default();
        let mut last = load.presentation();
        for step in steps {
            last = step(&mut load);
        }
        (load, last)
    }

    fn begin(load: &mut ContentLoad) -> LoadPresentation {
        load.begin()
    }

    fn replace(load: &mut ContentLoad) -> LoadPresentation {
        load.begin_replacing()
    }

    fn succeed(load: &mut ContentLoad) -> LoadPresentation {
        load.succeed()
    }

    fn failure() -> LoadFailure {
        LoadFailure::Page(std::sync::Arc::new(tablepro_session::OperationError::Closed))
    }

    fn fail(load: &mut ContentLoad) -> LoadPresentation {
        load.fail(failure())
    }

    fn abandon(load: &mut ContentLoad) -> LoadPresentation {
        load.abandon()
    }

    fn drop_content(load: &mut ContentLoad) -> LoadPresentation {
        load.drop_content()
    }

    #[test]
    fn content_load_transition_table() {
        let table: &[Case] = &[
            (&[], (Shown::Spinner, false, false)),
            (&[begin], (Shown::Spinner, true, false)),
            (&[begin, fail, begin], (Shown::Spinner, true, false)),
            (&[begin, succeed, begin], (Shown::Content, true, false)),
            (&[begin, succeed, begin, fail, begin], (Shown::Content, true, true)),
            (&[begin, fail], (Shown::Error, false, false)),
            (&[begin, succeed, begin, fail], (Shown::Content, false, true)),
            (&[begin, succeed], (Shown::Content, false, false)),
            (
                &[begin, succeed, begin, fail, begin, succeed],
                (Shown::Content, false, false),
            ),
            (&[begin, fail, begin, succeed], (Shown::Content, false, false)),
            (&[begin, succeed, replace], (Shown::Content, true, false)),
            (&[begin, succeed, replace, fail], (Shown::Error, false, false)),
            (&[begin, succeed, begin, fail, replace], (Shown::Content, true, false)),
            (&[begin, succeed, begin, abandon], (Shown::Content, false, false)),
            (
                &[begin, succeed, begin, fail, begin, abandon],
                (Shown::Content, false, true),
            ),
            (&[begin, abandon], (Shown::Spinner, false, false)),
            (&[begin, succeed, begin, drop_content], (Shown::Spinner, true, false)),
            (
                &[begin, succeed, begin, drop_content, fail],
                (Shown::Error, false, false),
            ),
        ];
        for (steps, expected) in table {
            let (_, presentation) = after(steps);
            assert_eq!(&shown(&presentation), expected, "after {} steps", steps.len());
        }
    }

    #[test]
    fn a_refresh_that_fails_again_shows_the_newest_failure() {
        let mut load = ContentLoad::default();
        load.begin();
        load.succeed();
        load.begin();
        load.fail(failure());
        load.begin();

        let presentation = load.fail(LoadFailure::Columns(std::sync::Arc::new(
            tablepro_session::OperationError::Cancelled,
        )));

        assert!(matches!(presentation.stale, Some(LoadFailure::Columns(_))));
        assert!(load.has_content());
    }
}
