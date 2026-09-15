use tablepro_storage::{ConnectionListState, DocumentProblem};

/// What the welcome view shows when the saved-connection list cannot be
/// read. `None` means there is nothing to say.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BannerContent {
    pub title: String,
    pub button_label: String,
}

pub(crate) fn banner_content(state: &ConnectionListState) -> Option<BannerContent> {
    let ConnectionListState::Unavailable(problem) = state else {
        return None;
    };
    Some(BannerContent {
        title: title_for(problem),
        button_label: crate::i18n::gettext("Reset…"),
    })
}

fn title_for(problem: &DocumentProblem) -> String {
    if problem.is_newer_version() {
        // Resetting here loses connections a newer build can still read,
        // so the wording points at the version rather than the file.
        crate::i18n::gettext("Saved connections were created by a newer version of TablePro")
    } else {
        crate::i18n::gettext("Saved connections could not be read")
    }
}

/// Names the file the store created, which is only known after the
/// rename. Saying it in advance was how the old wording went stale.
pub(crate) fn reset_toast_text(moved: &std::path::Path) -> String {
    let name = moved
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| moved.display().to_string());
    crate::i18n::gettext_f(
        "Saved connections were reset. The old file is {name}.",
        &[("name", &name)],
    )
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_storage::DocumentProblemKind;

    use super::*;

    fn problem(kind: DocumentProblemKind) -> ConnectionListState {
        ConnectionListState::Unavailable(Arc::new(DocumentProblem::new("/tmp/connections.json", kind)))
    }

    #[test]
    fn banner_content_per_state() {
        assert_eq!(banner_content(&ConnectionListState::Loading), None);
        assert_eq!(banner_content(&ConnectionListState::Ready(Arc::from(Vec::new()))), None);

        let corrupt = banner_content(&problem(DocumentProblemKind::Corrupt {
            detail: "x".to_owned(),
            line: 1,
            column: 2,
        }))
        .expect("a banner for a corrupt file");
        assert_eq!(corrupt.title, "Saved connections could not be read");
        assert_eq!(corrupt.button_label, "Reset…");

        let newer = banner_content(&problem(DocumentProblemKind::NewerVersion { found: 2, expected: 1 }))
            .expect("a banner for a newer file");
        assert_eq!(
            newer.title,
            "Saved connections were created by a newer version of TablePro"
        );
    }

    #[test]
    fn reset_toast_names_returned_path() {
        let text = reset_toast_text(std::path::Path::new(
            "/home/u/.config/tablepro/connections.json.corrupt-17",
        ));

        assert!(text.contains("connections.json.corrupt-17"), "{text}");
        assert!(
            !text.contains("/home/u"),
            "the toast should not spell out the directory: {text}"
        );
    }
}
