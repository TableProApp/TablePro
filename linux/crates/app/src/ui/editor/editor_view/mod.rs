mod caret;
mod imp;
mod matches;
mod paint;
mod pending;
#[cfg(test)]
mod tests;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib};
use sourceview5::prelude::*;

use self::caret::{Caret, Span, merged, selection};
use self::matches::Needle;
use self::pending::Pending;

glib::wrapper! {
    /// The SQL editor's source view, with cursors besides GTK's own on
    /// text marks (`docs/decisions/0024-multi-cursor-on-text-marks.md`).
    pub struct EditorView(ObjectSubclass<imp::EditorView>)
        @extends sourceview5::View, gtk::TextView, gtk::Widget,
        @implements gtk::Accessible, gtk::AccessibleText, gtk::Buildable, gtk::ConstraintTarget, gtk::Scrollable;
}

impl Default for EditorView {
    fn default() -> Self {
        glib::Object::new()
    }
}

/// Which caret a command runs at first.
#[derive(Debug, Clone, Copy)]
pub(super) enum Order {
    /// An undo puts the cursor back where the first edit was.
    PrimaryFirst,
    /// A deletion runs first at the caret whose text no other deletion
    /// reaches, so each caret deletes from the text as it was, unless
    /// another's deletion took it.
    Forward,
    Backward,
}

/// A command under way at every caret. Turn 0 is GTK's caret and turn
/// `i + 1` the other caret at `i`.
pub(super) struct Replay {
    primary: std::rc::Rc<Caret>,
    waiting: Vec<bool>,
    swallowed: Vec<bool>,
}

impl EditorView {
    pub(crate) fn connect_carets_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "carets-changed",
            false,
            glib::closure_local!(move |view: &Self| f(view)),
        )
    }

    pub(crate) fn caret_count(&self) -> usize {
        self.imp().carets.borrow().len() + 1
    }

    pub(crate) fn has_extra_carets(&self) -> bool {
        !self.imp().carets.borrow().is_empty()
    }

    pub(crate) fn caret_ranges(&self) -> Vec<(gtk::TextIter, gtk::TextIter)> {
        let buffer = self.buffer();
        let mut ranges: Vec<_> = self
            .imp()
            .carets
            .borrow()
            .iter()
            .map(|caret| caret.range(&buffer))
            .collect();
        let (mut start, mut end) = selection(&buffer);
        start.order(&mut end);
        ranges.push((start, end));
        ranges.sort_by_key(|(start, _)| start.offset());
        ranges
    }

    pub(crate) fn set_carets_enabled(&self, enabled: bool) {
        self.imp().disabled.set(!enabled);
        if !enabled {
            self.single_caret();
        }
    }

    /// GtkSourceView parents its completion list to the view as a
    /// popover, and while it shows, Return, Tab and Escape are its.
    pub(crate) fn shows_popup(&self) -> bool {
        let mut child = self.first_child();
        while let Some(widget) = child {
            if widget.is::<gtk::Popover>() && widget.is_visible() {
                return true;
            }
            child = widget.next_sibling();
        }
        false
    }

    pub(crate) fn carets_enabled(&self) -> bool {
        !self.imp().disabled.get()
    }

    /// `false` when there was one cursor already.
    pub(crate) fn single_caret(&self) -> bool {
        let imp = self.imp();
        self.forget_origin();
        imp.pending.take();
        imp.swallowed.take();
        let had = !imp.carets.take().is_empty();
        if had {
            self.carets_changed();
        }
        had
    }

    /// With nothing selected, the word at each caret is selected instead,
    /// and later matches are whole words only.
    pub(crate) fn add_caret_at_next_match(&self) -> bool {
        let imp = self.imp();
        if !self.takes_carets() {
            return false;
        }
        let buffer = self.buffer();
        let Some((start, end)) = buffer.selection_bounds() else {
            return self.select_words();
        };
        let needle = Needle {
            text: buffer.text(&start, &end, false).to_string(),
            whole_word: imp.word_search.get(),
        };
        let taken = self.taken();
        let Some((found_start, found_end)) =
            matches::next_match(&buffer, &needle, &end, |from, to| overlaps(&taken, from, to))
        else {
            self.error_bell();
            return false;
        };
        imp.carets.borrow_mut().push(Caret::at_selection(&buffer));
        self.place(&found_end, &found_start);
        imp.column_x.set(None);
        self.settle();
        self.scroll_mark_onscreen(&buffer.get_insert());
        true
    }

    pub(crate) fn add_carets_at_all_matches(&self) -> bool {
        let imp = self.imp();
        if !self.takes_carets() {
            return false;
        }
        let buffer = self.buffer();
        if buffer.selection_bounds().is_none() && !self.select_words() {
            return false;
        }
        let Some((start, end)) = buffer.selection_bounds() else {
            return false;
        };
        let needle = Needle {
            text: buffer.text(&start, &end, false).to_string(),
            whole_word: imp.word_search.get(),
        };
        let taken = self.taken();
        let found: Vec<Caret> = matches::all_matches(&buffer, &needle)
            .into_iter()
            .filter(|(from, to)| !overlaps(&taken, from.offset(), to.offset()))
            .map(|(from, to)| Caret::new(&buffer, &to, &from))
            .collect();
        if found.is_empty() {
            self.error_bell();
            return false;
        }
        imp.carets.borrow_mut().extend(found);
        self.settle();
        true
    }

    pub(crate) fn add_caret_on_next_line(&self, down: bool) -> bool {
        let imp = self.imp();
        if !self.takes_carets() {
            return false;
        }
        let buffer = self.buffer();
        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        let x = imp
            .column_x
            .get()
            .unwrap_or_else(|| self.cursor_locations(Some(&cursor)).0.x());
        let mut lines: Vec<i32> = imp
            .carets
            .borrow()
            .iter()
            .map(|caret| caret.insert(&buffer).line())
            .collect();
        lines.push(cursor.line());
        let edge = if down { lines.iter().max() } else { lines.iter().min() }
            .copied()
            .unwrap_or_else(|| cursor.line());
        let target = if down { edge + 1 } else { edge - 1 };
        let Some(line) = (target >= 0).then(|| buffer.iter_at_line(target)).flatten() else {
            self.error_bell();
            return false;
        };
        let (y, _) = self.line_yrange(&line);
        let at = self.iter_at_location(x, y).unwrap_or_else(|| {
            let mut end = line;
            if !end.ends_line() {
                end.forward_to_line_end();
            }
            end
        });
        imp.carets.borrow_mut().push(Caret::at_selection(&buffer));
        self.place(&at, &at);
        imp.word_search.set(false);
        imp.column_x.set(Some(x));
        self.settle();
        self.scroll_mark_onscreen(&buffer.get_insert());
        true
    }

    pub(crate) fn toggle_caret_at(&self, at: &gtk::TextIter) {
        let imp = self.imp();
        if !self.takes_carets() {
            return;
        }
        self.forget_origin();
        let buffer = self.buffer();
        let offset = at.offset();
        let covers = |span: Span| span.start <= offset && offset <= span.end;
        let hit = imp
            .carets
            .borrow()
            .iter()
            .position(|caret| covers(caret.span(&buffer, false)));
        if let Some(index) = hit {
            let removed = imp.carets.borrow_mut().remove(index);
            drop(removed);
            self.carets_changed();
            return;
        }
        if covers(primary_span(&buffer)) {
            let next = imp.carets.borrow_mut().pop();
            if let Some(next) = next {
                self.place(&next.insert(&buffer), &next.anchor(&buffer));
                self.carets_changed();
            }
            return;
        }
        imp.carets.borrow_mut().push(Caret::at_selection(&buffer));
        self.place(at, at);
        self.settle();
    }

    /// An edit of the editor's own that works out every caret itself, so
    /// the carets do not repeat it.
    pub(crate) fn edit_once(&self, edit: impl FnOnce()) {
        let imp = self.imp();
        let buffer = self.buffer();
        // Text the edit puts where a caret is goes before it, as GTK's own
        // cursor takes it, so every caret keeps its place in the code.
        let followers: Vec<[gtk::TextMark; 2]> = imp
            .carets
            .borrow()
            .iter()
            .map(|caret| {
                [
                    buffer.create_mark(None, &caret.insert(&buffer), false),
                    buffer.create_mark(None, &caret.anchor(&buffer), false),
                ]
            })
            .collect();
        let was = imp.busy.replace(true);
        edit();
        imp.busy.set(was);
        for (caret, [insert, anchor]) in imp.carets.borrow().iter().zip(&followers) {
            caret.set(&buffer, &buffer.iter_at_mark(insert), &buffer.iter_at_mark(anchor));
            buffer.delete_mark(insert);
            buffer.delete_mark(anchor);
        }
        self.settle();
    }

    /// Forwarding a key to the view runs every controller it has, and a
    /// controller the forward reaches forgets the key, so this one goes on
    /// an ancestor of the view.
    pub(crate) fn caret_keys(&self) -> gtk::EventControllerKey {
        let keys = gtk::EventControllerKey::new();
        keys.set_name(Some("tablepro-carets"));
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let view = self.downgrade();
        keys.connect_key_pressed(move |keys, keyval, _, state| {
            view.upgrade().map_or(glib::Propagation::Proceed, |view| {
                view.key_at_every_caret(keys, keyval, state)
            })
        });
        keys
    }

    fn setup(&self) {
        let click = gtk::GestureClick::new();
        click.set_button(0);
        click.set_propagation_phase(gtk::PropagationPhase::Capture);
        let view = self.downgrade();
        click.connect_pressed(move |click, presses, x, y| {
            if let Some(view) = view.upgrade() {
                view.pressed(click, presses, x, y);
            }
        });
        self.add_controller(click);

        self.connect_has_focus_notify(|view| view.queue_draw());
        self.connect_overwrite_notify(|view| {
            if view.overwrites() {
                view.single_caret();
            }
        });
        // An input method's text has not come yet while it composes.
        self.connect_preedit_changed(|view, preedit| {
            let was = view.imp().composing.replace(!preedit.is_empty());
            if was && preedit.is_empty() && view.has_extra_carets() {
                view.settle_when_idle();
            }
        });
        self.connect_buffer_notify(|view| view.follow_buffer());
        self.follow_buffer();
        self.follow_source_signals();
    }

    fn follow_buffer(&self) {
        let imp = self.imp();
        if imp.disposed.get() {
            return;
        }
        imp.handlers.take();
        imp.carets.take();
        imp.pending.take();
        imp.in_user_action.set(false);
        imp.restoring.set(false);
        let buffer = self.buffer();
        let mut ids = vec![
            buffer.connect_insert_text(glib::clone!(
                #[weak(rename_to = view)]
                self,
                move |buffer, at, text| view.record(|| Pending::of_insert(buffer, at, text))
            )),
            buffer.connect_delete_range(glib::clone!(
                #[weak(rename_to = view)]
                self,
                move |buffer, start, end| {
                    view.swallow(start, end);
                    view.record(|| Pending::of_delete(buffer, start, end));
                }
            )),
            buffer.connect_begin_user_action(glib::clone!(
                #[weak(rename_to = view)]
                self,
                move |_| {
                    view.imp().in_user_action.set(true);
                    view.imp().swallowed.take();
                }
            )),
            buffer.connect_end_user_action(glib::clone!(
                #[weak(rename_to = view)]
                self,
                move |_| view.apply_pending()
            )),
            buffer.connect_mark_set(glib::clone!(
                #[weak(rename_to = view)]
                self,
                move |buffer, _, mark| view.mark_moved(buffer, mark)
            )),
            buffer.connect_changed(glib::clone!(
                #[weak(rename_to = view)]
                self,
                move |_| {
                    let imp = view.imp();
                    if !imp.busy.get() && !imp.in_user_action.get() && !imp.restoring.get() {
                        view.settle();
                    }
                }
            )),
        ];
        // GTK's history puts back its own cursor only, so an undo or a redo
        // returns to one cursor, where the edit was.
        for name in ["undo", "redo"] {
            ids.push(buffer.connect_local(
                name,
                false,
                glib::clone!(
                    #[weak(rename_to = view)]
                    self,
                    #[upgrade_or]
                    None,
                    move |_| {
                        view.imp().restoring.set(true);
                        None
                    }
                ),
            ));
            ids.push(buffer.connect_local(
                name,
                true,
                glib::clone!(
                    #[weak(rename_to = view)]
                    self,
                    #[upgrade_or]
                    None,
                    move |_| {
                        view.imp().restoring.set(false);
                        view.single_caret();
                        None
                    }
                ),
            ));
        }
        imp.handlers.replace(Some(imp::BufferHandlers {
            buffer: buffer.downgrade(),
            ids,
        }));
        self.block_completion_and_snippets(false);
        self.queue_draw();
    }

    /// GtkSourceView's own commands with no class method to override.
    fn follow_source_signals(&self) {
        for name in ["change-case", "change-number", "move-to-matching-bracket"] {
            let view = self.downgrade();
            self.connect_local(name, false, move |values| {
                let view = view.upgrade()?;
                if view.runs_per_caret() {
                    view.stop_signal_emission_by_name(name);
                    let args: Vec<glib::Value> = values.iter().skip(1).cloned().collect();
                    view.at_every_caret(|_| {
                        view.emit_by_name_with_values(name, &args);
                    });
                }
                None
            });
        }
        // Joins the lines around the cursor, which two carets on one line
        // would join twice.
        let view = self.downgrade();
        self.connect_local("join-lines", false, move |_| {
            if let Some(view) = view.upgrade()
                && view.runs_per_caret()
            {
                view.single_caret();
            }
            None
        });
    }

    fn runs_per_caret(&self) -> bool {
        let imp = self.imp();
        !imp.busy.get() && !imp.disabled.get() && self.has_extra_carets()
    }

    /// The selection a next-match search reads, and the column a caret
    /// above or below lands in, belong to the carets as they were made;
    /// a move or an edit at the carets ends both.
    fn forget_origin(&self) {
        let imp = self.imp();
        imp.word_search.set(false);
        imp.column_x.set(None);
        imp.columns.take();
    }

    /// GTK starts each caret's Up or Down from where the caret is now, so
    /// the move lands each caret back on its own column.
    pub(super) fn move_vertically(&self, extend: bool, step: impl Fn()) {
        let imp = self.imp();
        let buffer = self.buffer();
        let columns = imp
            .columns
            .take()
            .filter(|columns| columns.len() == self.caret_count())
            .unwrap_or_else(|| self.columns());
        self.at_every_caret(|place| {
            let from = buffer.iter_at_mark(&buffer.get_insert());
            step();
            let to = buffer.iter_at_mark(&buffer.get_insert());
            let Some(&x) = columns.get(place).filter(|_| to.line() != from.line()) else {
                return;
            };
            let (y, _) = self.line_yrange(&to);
            let target = self.iter_at_location(x, y).unwrap_or_else(|| {
                let mut end = to;
                if !end.ends_line() {
                    end.forward_to_line_end();
                }
                end
            });
            if extend {
                buffer.move_mark(&buffer.get_insert(), &target);
            } else {
                buffer.place_cursor(&target);
            }
        });
        if columns.len() == self.caret_count() {
            imp.columns.replace(Some(columns));
        }
    }

    /// Each caret's column, in the order `places` gives.
    fn columns(&self) -> Vec<i32> {
        let buffer = self.buffer();
        let (insert, anchor) = selection(&buffer);
        let mut carets: Vec<(i32, gtk::TextIter)> = std::iter::once((insert.offset().min(anchor.offset()), insert))
            .chain(
                self.imp()
                    .carets
                    .borrow()
                    .iter()
                    .map(|caret| (caret.range(&buffer).0.offset(), caret.insert(&buffer))),
            )
            .collect();
        carets.sort_by_key(|(start, _)| *start);
        carets
            .iter()
            .map(|(_, insert)| self.cursor_locations(Some(insert)).0.x())
            .collect()
    }

    fn at_every_caret(&self, op: impl Fn(usize)) {
        self.at_every_caret_in(Order::PrimaryFirst, op);
    }

    /// GTK's cursor stands in for each caret in turn, so `op` is GTK's own
    /// command. `op` gets the caret's place in the document.
    pub(super) fn at_every_caret_in(&self, order: Order, op: impl Fn(usize)) {
        let imp = self.imp();
        let buffer = self.buffer();
        self.forget_origin();
        let primary = std::rc::Rc::new(Caret::at_selection(&buffer));
        let places = self.places(&primary);
        let mut turns: Vec<usize> = (0..places.len()).collect();
        match order {
            Order::PrimaryFirst => {}
            Order::Forward => turns.sort_by_key(|&turn| places.get(turn).copied()),
            Order::Backward => turns.sort_by_key(|&turn| std::cmp::Reverse(places.get(turn).copied())),
        }
        let was = imp.busy.replace(true);
        imp.replay.replace(Some(Replay {
            primary: primary.clone(),
            waiting: vec![true; places.len()],
            swallowed: vec![false; places.len()],
        }));
        buffer.begin_user_action();
        for turn in turns {
            let swallowed = match imp.replay.borrow_mut().as_mut() {
                Some(replay) => {
                    if let Some(waiting) = replay.waiting.get_mut(turn) {
                        *waiting = false;
                    }
                    replay.swallowed.get(turn).copied().unwrap_or(true)
                }
                None => false,
            };
            let ends = match turn.checked_sub(1) {
                None => Some((primary.insert(&buffer), primary.anchor(&buffer))),
                Some(index) => imp
                    .carets
                    .borrow()
                    .get(index)
                    .map(|caret| (caret.insert(&buffer), caret.anchor(&buffer))),
            };
            let Some((insert, anchor)) = ends.filter(|_| !swallowed) else {
                continue;
            };
            buffer.select_range(&insert, &anchor);
            op(places.get(turn).copied().unwrap_or_default());
            match turn.checked_sub(1) {
                None => primary.follow_selection(&buffer),
                Some(index) => {
                    if let Some(caret) = imp.carets.borrow().get(index) {
                        caret.follow_selection(&buffer);
                    }
                }
            }
        }
        let swallowed = imp.replay.take().map(|replay| replay.swallowed).unwrap_or_default();
        // A caret another took sits where that one is now, and settling
        // joins the two.
        let dropped = swallowed.iter().skip(1).any(|&swallowed| swallowed);
        self.drop_carets(|index| swallowed.get(index + 1).copied().unwrap_or(false));
        primary.select(&buffer);
        buffer.end_user_action();
        imp.busy.set(was);
        drop(primary);
        if self.has_extra_carets() {
            self.settle();
        } else if dropped {
            self.carets_changed();
        }
        self.scroll_mark_onscreen(&buffer.get_insert());
    }

    /// Each caret's place in the document, GTK's own first.
    fn places(&self, primary: &Caret) -> Vec<usize> {
        let buffer = self.buffer();
        let mut starts: Vec<(i32, usize)> = std::iter::once(primary.range(&buffer).0.offset())
            .chain(
                self.imp()
                    .carets
                    .borrow()
                    .iter()
                    .map(|caret| caret.range(&buffer).0.offset()),
            )
            .enumerate()
            .map(|(index, start)| (start, index))
            .collect();
        starts.sort_unstable();
        let mut places = vec![0; starts.len()];
        for (place, (_, index)) in starts.into_iter().enumerate() {
            if let Some(slot) = places.get_mut(index) {
                *slot = place;
            }
        }
        places
    }

    /// A caret inside text another caret's command deletes would act again
    /// on what is left around it, so it sits this command out and joins
    /// the other.
    fn swallow(&self, start: &gtk::TextIter, end: &gtk::TextIter) {
        let imp = self.imp();
        let buffer = self.buffer();
        let (from, to) = (start.offset().min(end.offset()), start.offset().max(end.offset()));
        // A selection the deletion covers goes with it; an empty caret at
        // its edge belongs to the text beside it.
        let inside = |caret: &Caret| {
            let span = caret.span(&buffer, false);
            if span.start == span.end {
                from < span.start && span.start < to
            } else {
                from <= span.start && span.end <= to
            }
        };
        if let Some(Replay {
            primary,
            waiting,
            swallowed,
        }) = imp.replay.borrow_mut().as_mut()
        {
            let carets = imp.carets.borrow();
            for (turn, caret) in std::iter::once(&**primary).chain(carets.iter()).enumerate() {
                if waiting.get(turn).copied().unwrap_or(false)
                    && inside(caret)
                    && let Some(slot) = swallowed.get_mut(turn)
                {
                    *slot = true;
                }
            }
            return;
        }
        if !imp.busy.get() && !imp.restoring.get() && imp.in_user_action.get() {
            let carets = imp.carets.borrow();
            let taken = carets.iter().enumerate().filter(|(_, caret)| inside(caret));
            imp.swallowed.borrow_mut().extend(taken.map(|(index, _)| index));
        }
    }

    /// Drops the carets at `swallowed`, indices into the carets as they
    /// stand.
    fn drop_carets(&self, swallowed: impl Fn(usize) -> bool) {
        let mut index = 0;
        self.imp().carets.borrow_mut().retain(|_| {
            let keep = !swallowed(index);
            index += 1;
            keep
        });
    }

    /// Lines go once, so only the first caret on a line stays.
    fn one_caret_per_line(&self) {
        let buffer = self.buffer();
        let mut lines = std::collections::HashSet::from([buffer.iter_at_mark(&buffer.get_insert()).line()]);
        let mut carets = self.imp().carets.borrow_mut();
        let before = carets.len();
        carets.retain(|caret| lines.insert(caret.insert(&buffer).line()));
        let removed = carets.len() != before;
        drop(carets);
        if removed {
            self.carets_changed();
        }
    }

    /// A move of GTK's cursor that is not the user's, which would return to
    /// one cursor.
    fn place(&self, insert: &gtk::TextIter, anchor: &gtk::TextIter) {
        let was = self.imp().busy.replace(true);
        self.buffer().select_range(insert, anchor);
        self.imp().busy.set(was);
    }

    fn settle(&self) {
        let imp = self.imp();
        let buffer = self.buffer();
        let carets = imp.carets.take();
        if carets.is_empty() {
            return;
        }
        let spans: Vec<Span> = std::iter::once(primary_span(&buffer))
            .chain(carets.iter().map(|caret| caret.span(&buffer, false)))
            .collect();
        let joined = merged(spans.clone());
        if joined.len() == spans.len() {
            imp.carets.replace(carets);
            self.carets_changed();
            return;
        }
        self.rebuild(&joined);
        drop(carets);
    }

    /// Carets where `spans` say, GTK's own where the primary is.
    fn rebuild(&self, spans: &[Span]) {
        let buffer = self.buffer();
        let last = buffer.char_count();
        let mut kept = Vec::with_capacity(spans.len());
        for span in spans {
            let (insert, anchor) = span.ends();
            let insert = buffer.iter_at_offset(insert.min(last));
            let anchor = buffer.iter_at_offset(anchor.min(last));
            if span.primary {
                self.place(&insert, &anchor);
            } else if !self.imp().disabled.get() {
                kept.push(Caret::new(&buffer, &insert, &anchor));
            }
        }
        let old = self.imp().carets.replace(kept);
        drop(old);
        self.carets_changed();
    }

    fn carets_changed(&self) {
        // A new set of carets starts its columns again; Up and Down put
        // theirs back once they have moved.
        self.imp().columns.take();
        self.block_completion_and_snippets(self.has_extra_carets());
        self.queue_draw();
        self.emit_by_name::<()>("carets-changed", &[]);
    }

    /// A completion replaces the word at GTK's cursor alone, and a
    /// snippet's stops follow GTK's cursor alone, so neither runs while
    /// there are other carets.
    fn block_completion_and_snippets(&self, block: bool) {
        let imp = self.imp();
        if block == imp.completion_blocked.get() {
            return;
        }
        let completion = self.completion();
        if block {
            completion.block_interactive();
            imp.snippets_enabled.set(self.enables_snippets());
            // Turning snippets off also ends the one being filled in.
            self.set_enable_snippets(false);
        } else {
            completion.unblock_interactive();
            self.set_enable_snippets(imp.snippets_enabled.get());
        }
        imp.completion_blocked.set(block);
    }

    /// Overwrite takes the character after GTK's cursor, which the other
    /// carets could not follow, so it keeps one cursor, as Vim mode does.
    fn takes_carets(&self) -> bool {
        !self.imp().disabled.get() && !self.overwrites()
    }

    fn taken(&self) -> Vec<(i32, i32)> {
        let buffer = self.buffer();
        std::iter::once(primary_span(&buffer))
            .chain(
                self.imp()
                    .carets
                    .borrow()
                    .iter()
                    .map(|caret| caret.span(&buffer, false)),
            )
            .map(|span| (span.start, span.end))
            .collect()
    }

    fn select_words(&self) -> bool {
        let buffer = self.buffer();
        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        if matches::word_at(&cursor).is_none() {
            self.error_bell();
            return false;
        }
        self.at_every_caret(|_| {
            let cursor = buffer.iter_at_mark(&buffer.get_insert());
            if let Some((start, end)) = matches::word_at(&cursor) {
                buffer.select_range(&end, &start);
            }
        });
        self.imp().word_search.set(true);
        true
    }

    fn record(&self, pending: impl FnOnce() -> Option<Pending>) {
        let imp = self.imp();
        if imp.busy.get()
            || imp.restoring.get()
            || !imp.in_user_action.get()
            || imp.carets.borrow().is_empty()
            || !self.has_focus()
        {
            return;
        }
        if let Some(pending) = pending() {
            pending.reserve(&self.buffer(), &imp.carets.borrow());
            imp.pending.borrow_mut().push(pending);
        }
    }

    /// GTK emits end-user-action before it closes the undo group, so what
    /// this adds is in the same undo step as what it repeats.
    fn apply_pending(&self) {
        let imp = self.imp();
        imp.in_user_action.set(false);
        if imp.busy.get() {
            return;
        }
        let swallowed = imp.swallowed.take();
        let edits = imp.pending.take();
        if swallowed.is_empty() && edits.is_empty() {
            return;
        }
        self.drop_carets(|index| swallowed.contains(&index));
        if !edits.is_empty() {
            self.repeat(&edits);
        }
        if !self.has_extra_carets() {
            self.carets_changed();
        } else if !edits.is_empty() && edits.iter().all(|edit| *edit == Pending::DeleteSelection) {
            // GTK commits text typed over a selection as two user actions,
            // the deletion and then the text (gtk_text_view_commit_text),
            // and an input method deletes it when it starts composing, so
            // carets the deletion brought together still type apart.
            self.settle_when_idle();
        } else {
            self.settle();
        }
    }

    fn settle_when_idle(&self) {
        let view = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(view) = view.upgrade()
                && !view.imp().disposed.get()
                && !view.imp().composing.get()
                && view.has_extra_carets()
            {
                view.settle();
            }
        });
    }

    fn repeat(&self, edits: &[Pending]) {
        let imp = self.imp();
        let buffer = self.buffer();
        self.forget_origin();
        let carets = imp.carets.take();
        // GTK's own marks would move past text a caret types where it is.
        let primary = Caret::at_selection(&buffer);
        imp.busy.set(true);
        buffer.begin_user_action();
        for caret in &carets {
            for edit in edits {
                edit.apply(&buffer, caret);
            }
            caret.clear_reserved();
        }
        buffer.end_user_action();
        primary.select(&buffer);
        imp.busy.set(false);
        imp.carets.replace(carets);
        drop(primary);
    }

    fn mark_moved(&self, buffer: &gtk::TextBuffer, mark: &gtk::TextMark) {
        let imp = self.imp();
        if imp.busy.get() || imp.restoring.get() || (*mark != buffer.get_insert() && *mark != buffer.selection_bound())
        {
            return;
        }
        imp.word_search.set(false);
        imp.column_x.set(None);
        self.single_caret();
    }

    fn copy_carets(&self) -> bool {
        let buffer = self.buffer();
        let pieces: Vec<String> = self
            .caret_ranges()
            .iter()
            .filter(|(start, end)| start != end)
            .map(|(start, end)| buffer.text(start, end, false).to_string())
            .collect();
        if pieces.is_empty() {
            return false;
        }
        self.clipboard().set_text(&pieces.join("\n"));
        true
    }

    fn cut_carets(&self) {
        if !self.copy_carets() {
            return;
        }
        let buffer = self.buffer();
        let editable = self.is_editable();
        self.at_every_caret(|_| {
            buffer.delete_selection(true, editable);
        });
    }

    fn paste_at_carets(&self) {
        let clipboard = self.clipboard();
        let view = self.downgrade();
        glib::spawn_future_local(async move {
            let Ok(Some(text)) = clipboard.read_text_future().await else {
                return;
            };
            if let Some(view) = view.upgrade() {
                view.insert_at_carets(&text);
            }
        });
    }

    /// A copy from as many carets has as many lines.
    fn insert_at_carets(&self, text: &str) {
        let lines: Vec<&str> = text.split('\n').map(|line| line.trim_end_matches('\r')).collect();
        let spread = self.caret_count() > 1 && lines.len() == self.caret_count();
        let buffer = self.buffer();
        let editable = self.is_editable();
        self.at_every_caret(|place| {
            let piece = if spread {
                lines.get(place).copied().unwrap_or(text)
            } else {
                text
            };
            buffer.delete_selection(true, editable);
            buffer.insert_interactive_at_cursor(piece, editable);
        });
    }

    /// The keys GtkSourceView's own key handler edits with
    /// (gtksourceview.c, gtk_source_view_key_pressed), so auto-indent, tab
    /// width and Ctrl+BackSpace work out each caret's own text. The input
    /// method sees the key first, as there.
    fn key_at_every_caret(
        &self,
        keys: &gtk::EventControllerKey,
        keyval: gdk::Key,
        state: gdk::ModifierType,
    ) -> glib::Propagation {
        if !self.runs_per_caret()
            || !self.is_editable()
            || !self.has_focus()
            || !is_caret_key(keyval, state)
            || self.shows_popup()
        {
            return glib::Propagation::Proceed;
        }
        let Some(event) = keys.current_event() else {
            return glib::Propagation::Proceed;
        };
        if self.im_context_filter_keypress(&event) {
            return glib::Propagation::Stop;
        }
        if matches!(keyval, gdk::Key::Tab | gdk::Key::KP_Tab | gdk::Key::ISO_Left_Tab) {
            let unindent = keyval == gdk::Key::ISO_Left_Tab || state.contains(gdk::ModifierType::SHIFT_MASK);
            self.tab_at_every_caret(unindent, || {
                keys.forward(self);
            });
        } else {
            // BackSpace deletes before each caret.
            let order = if keyval == gdk::Key::BackSpace {
                Order::Backward
            } else {
                Order::PrimaryFirst
            };
            self.at_every_caret_in(order, |_| {
                keys.forward(self);
            });
        }
        glib::Propagation::Stop
    }

    /// Tab on whole lines indents them, which carets sharing a line would
    /// do once each, so every such line gets one level, through
    /// GtkSourceView's own indenting, and `forward` runs Tab at the other
    /// carets. Which carets indent is settled first, since indenting
    /// moves where their selections start.
    fn tab_at_every_caret(&self, unindent: bool, forward: impl Fn()) {
        let ranges = self.caret_ranges();
        let line_wise: Vec<bool> = ranges
            .iter()
            .map(|(start, end)| indented_lines(start, end, unindent).is_some())
            .collect();
        let lines: std::collections::BTreeSet<i32> = ranges
            .iter()
            .filter_map(|(start, end)| indented_lines(start, end, unindent))
            .flatten()
            .collect();
        let indented = std::cell::Cell::new(false);
        self.at_every_caret(|place| {
            if !indented.replace(true) {
                // Indentation the carets share takes no caret with it.
                let replay = self.imp().replay.take();
                self.indent_blocks(&lines, unindent);
                self.imp().replay.replace(replay);
            }
            if !line_wise.get(place).copied().unwrap_or(true) {
                forward();
            }
        });
    }

    fn indent_blocks(&self, lines: &std::collections::BTreeSet<i32>, unindent: bool) {
        let Some(&first) = lines.first() else {
            return;
        };
        let mut blocks = vec![(first, first)];
        for &line in lines {
            match blocks.last_mut() {
                Some((_, last)) if line <= *last + 1 => *last = line,
                _ => blocks.push((line, line)),
            }
        }
        let buffer = self.buffer();
        for (first, last) in blocks {
            let (Some(mut start), Some(mut end)) = (buffer.iter_at_line(first), buffer.iter_at_line(last)) else {
                continue;
            };
            if !end.ends_line() {
                end.forward_to_line_end();
            }
            if unindent {
                self.unindent_lines(&mut start, &mut end);
            } else {
                self.indent_lines(&mut start, &mut end);
            }
        }
    }

    fn pressed(&self, click: &gtk::GestureClick, presses: i32, x: f64, y: f64) {
        let button = click.current_button();
        let state = click.current_event_state() & gtk::accelerator_get_default_mod_mask();
        let toggles = button == gdk::BUTTON_PRIMARY
            && self.takes_carets()
            && crate::application::component_matches("editor.toggle-cursor", gdk::Key::Pointer_Button1, state);
        if !toggles {
            // A click puts the cursor somewhere else, and a drag takes the
            // selection, so the other carets go first.
            if matches!(button, gdk::BUTTON_PRIMARY | gdk::BUTTON_MIDDLE) {
                self.single_caret();
            }
            click.set_state(gtk::EventSequenceState::Denied);
            return;
        }
        click.set_state(gtk::EventSequenceState::Claimed);
        if presses != 1 {
            return;
        }
        self.grab_focus();
        let at = self.iter_at_point(x, y);
        self.toggle_caret_at(&at);
    }

    fn iter_at_point(&self, x: f64, y: f64) -> gtk::TextIter {
        let (x, y) = self.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        if let Some(at) = self.iter_at_location(x, y) {
            return at;
        }
        let (mut line, _) = self.line_at_y(y);
        if x > self.iter_location(&line).x() && !line.ends_line() {
            line.forward_to_line_end();
        }
        line
    }
}

/// A match that shares text with a caret's selection, or has a caret
/// inside it, would join it rather than add one.
fn overlaps(taken: &[(i32, i32)], from: i32, to: i32) -> bool {
    taken
        .iter()
        .any(|&(start, end)| (start, end) == (from, to) || (from < end.max(start + 1) && start < to))
}

fn primary_span(buffer: &gtk::TextBuffer) -> Span {
    let (insert, anchor) = selection(buffer);
    Span::of(insert.offset(), anchor.offset(), true)
}

/// The lines GtkSourceView's Tab indents for a selection, as
/// gtk_source_view_key_pressed decides: Shift+Tab always, Tab when the
/// selection takes whole lines or runs over more than one.
fn indented_lines(start: &gtk::TextIter, end: &gtk::TextIter, unindent: bool) -> Option<std::ops::RangeInclusive<i32>> {
    let (mut start, mut end) = (*start, *end);
    start.order(&mut end);
    let whole = start != end && ((start.starts_line() && end.ends_line()) || start.line() != end.line());
    if !unindent && !whole {
        return None;
    }
    let mut last = end.line();
    if end.starts_line() && last > start.line() {
        last -= 1;
    }
    Some(start.line()..=last)
}

fn is_caret_key(keyval: gdk::Key, state: gdk::ModifierType) -> bool {
    let modifiers = state & gtk::accelerator_get_default_mod_mask();
    let shift = gdk::ModifierType::SHIFT_MASK;
    match keyval {
        gdk::Key::Return
        | gdk::Key::KP_Enter
        | gdk::Key::ISO_Enter
        | gdk::Key::Tab
        | gdk::Key::KP_Tab
        | gdk::Key::ISO_Left_Tab => modifiers.difference(shift).is_empty(),
        gdk::Key::BackSpace => modifiers.difference(shift | gdk::ModifierType::CONTROL_MASK).is_empty(),
        _ => false,
    }
}
