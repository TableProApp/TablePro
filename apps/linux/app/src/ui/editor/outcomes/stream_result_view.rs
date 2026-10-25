use super::*;
pub(in crate::ui::editor) use super::{build_stream_page_widget, result_view_key};

pub(in crate::ui::editor) fn build_streamed_result_widget(
    outcome: &StatementOutcome,
    result: &StreamedResult,
    grid_sender: &relm4::Sender<GridMsg>,
    connection_id: Option<uuid::Uuid>,
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    settings_store: LocalResultSettingsStore,
    sender: Option<&relm4::ComponentSender<super::super::SqlEditor>>,
) -> gtk::Widget {
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let page_switcher = gtk::Stack::builder().vexpand(true).hexpand(true).build();
    let target = super::super::stream_view::LiveStreamTarget {
        grid_sender,
        connection_id,
        database: database.clone(),
        settings_store: settings_store.clone(),
    };
    for page_index in 0..result.total_pages {
        let container = stream_page_container(result, outcome.identity, page_index, &target);
        page_switcher.add_titled(
            &container,
            Some(container.widget_name().as_str()),
            &stream_page_label(result, page_index as usize),
        );
    }
    if let Some(page) = stream_terminal_page(result, outcome.identity.statement_index) {
        page_switcher.add_titled(&page, Some("status"), &crate::tr!("Status"));
    }
    if let Some(last) = page_switcher.last_child() {
        page_switcher.set_visible_child(&last);
    }
    if let Some(sender) = sender {
        super::super::stream_view::install_page_loader(&page_switcher, result, outcome.identity, sender);
    }
    let progress = gtk::Label::new(Some(&stream_progress_text(result)));
    progress.set_wrap(true);
    if matches!(result.terminal, StreamTerminal::Loading) {
        page_switcher.set_widget_name(super::super::stream_view::LIVE_PAGES);
        progress.set_widget_name(super::super::stream_view::LIVE_PROGRESS);
    }
    holder.append(&progress);
    if let Some(request) = result.export.clone() {
        let export = gtk::Button::with_label(&crate::tr!("Export all rows…"));
        export.add_css_class("flat");
        export.connect_clicked({
            let grid_sender = grid_sender.clone();
            move |_| {
                let _ = grid_sender.send(GridMsg::ExportStreamedResults(request.clone()));
            }
        });
        holder.append(&export);
        holder.append(&gtk::Label::new(Some(&crate::tr!(
            "The query will run again through a guarded cursor."
        ))));
    }
    holder.append(&super::super::stream_view::build_pager(&page_switcher));
    holder.append(&page_switcher);
    holder.upcast()
}

pub(in crate::ui::editor) fn stream_page_container(
    result: &StreamedResult,
    identity: StatementIdentity,
    page_index: u64,
    target: &super::super::stream_view::LiveStreamTarget<'_>,
) -> gtk::Box {
    let container = gtk::Box::new(gtk::Orientation::Vertical, 0);
    container.set_widget_name(&super::super::stream_view::page_widget_name(
        result.generation,
        page_index,
    ));
    let resident = result
        .page_indices
        .binary_search(&page_index)
        .ok()
        .and_then(|position| result.pages.get(position));
    if let Some(page) = resident {
        container.add_css_class("tp-stream-page-ram-resident");
        container.append(&build_stream_page_widget(
            page,
            target.grid_sender,
            target.connection_id,
            target.database.clone(),
            target.settings_store.clone(),
            result_view_key(identity, page_index as usize),
        ));
    } else {
        container.append(&stream_page_placeholder(result, page_index));
    }
    container
}

pub(in crate::ui::editor) fn replace_stream_page_content(container: &gtk::Box, page: &gtk::Widget) {
    clear_box(container);
    container.append(page);
}

pub(in crate::ui::editor) fn stream_page_placeholder(result: &StreamedResult, page_index: u64) -> gtk::Widget {
    stream_page_placeholder_with_title(stream_page_label(result, page_index as usize))
}

pub(in crate::ui::editor) fn stream_page_placeholder_with_title(title: String) -> gtk::Widget {
    let page = adw::StatusPage::builder()
        .title(title)
        .description(crate::tr!("Select this page to load it from temporary storage."))
        .icon_name("document-open-recent-symbolic")
        .vexpand(true)
        .build();
    page.add_css_class("tp-stream-page-placeholder");
    page.upcast()
}

pub(in crate::ui::editor) fn stream_progress_text(result: &StreamedResult) -> String {
    let rows = crate::trn!("Received {rows} row", "Received {rows} rows", result.total_rows)
        .replace("{rows}", &result.total_rows.to_string());
    let pages = crate::trn!("{pages} page", "{pages} pages", result.total_pages)
        .replace("{pages}", &result.total_pages.to_string());
    let received = format!("{rows} · {pages}");
    let retained: usize = result.pages.iter().map(|page| page.rows.len()).sum();
    if retained == result.total_rows {
        return received;
    }
    let notice = crate::tr!("Earlier pages can be loaded from temporary storage.");
    format!("{received}\n{notice}")
}

pub(in crate::ui::editor) fn stream_page_label(result: &StreamedResult, page_index: usize) -> String {
    let Some(count) = result
        .page_row_counts
        .get(page_index)
        .copied()
        .filter(|count| *count > 0)
    else {
        return crate::tr!("Rows 0");
    };
    let start = result
        .page_row_counts
        .iter()
        .take(page_index)
        .sum::<usize>()
        .saturating_add(1);
    let end = start.saturating_add(count.saturating_sub(1));
    crate::tr!("Rows {start}-{end}")
        .replace("{start}", &start.to_string())
        .replace("{end}", &end.to_string())
}

fn stream_terminal_page(result: &StreamedResult, statement_index: usize) -> Option<gtk::Widget> {
    match &result.terminal {
        StreamTerminal::Loading | StreamTerminal::Complete => None,
        StreamTerminal::Failed(message) => Some(error_page(statement_index, message).upcast()),
        StreamTerminal::Cancelled => Some(
            adw::StatusPage::builder()
                .title(crate::tr!("Query cancelled"))
                .description(crate::tr!("All received pages remain available."))
                .icon_name("process-stop-symbolic")
                .vexpand(true)
                .build()
                .upcast(),
        ),
        StreamTerminal::TimedOut => Some(
            adw::StatusPage::builder()
                .title(crate::tr!("Query timed out"))
                .description(crate::tr!("All received pages remain available."))
                .icon_name("dialog-warning-symbolic")
                .vexpand(true)
                .build()
                .upcast(),
        ),
    }
}
