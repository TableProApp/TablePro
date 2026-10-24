use super::SqlEditorInput;

pub(super) fn blocks_execution(input: &SqlEditorInput) -> bool {
    matches!(
        input,
        SqlEditorInput::Run
            | SqlEditorInput::RunWithParameters { .. }
            | SqlEditorInput::RunWithLongerTimeout
            | SqlEditorInput::RunAtCursor
            | SqlEditorInput::Explain
    )
}
