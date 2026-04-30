//! Inline filter strip — server-side WHERE clause editor that slides
//! in above the Browse-tab grid. Reachable via the Filter button on
//! the paginator action bar or the Ctrl+R shortcut.
//!
//! Why inline (vs. a modal dialog)? The user is filtering data they
//! can see; obscuring the grid with a dialog adds a round-trip every
//! time they want to tune a rule. The strip stays open while the user
//! edits, applies on demand, collapses with Esc / Close. Matches
//! GtkSearchBar's slide-in pattern (the native GNOME idiom for
//! "transient editor above content") rather than the heavier
//! AdwDialog "form-with-validate-then-apply" flow.
//!
//! UI shape (single-level combinator, no nested groups):
//!
//! ```text
//! ┌─ Filter rows ──────────────────── Clear all │ Apply │ ✕ ─┐
//! │  Combine rules with: [ All  ▾ ]   <— AND or OR DropDown   │
//! │  ┌─ boxed-list ListBox ─────────────────────────────────┐ │
//! │  │ [Column ▾] [Op ▾] [Value …]                  [✕]      │ │
//! │  │ [Column ▾] [Op ▾] [Value …]                  [✕]      │ │
//! │  │ [+ Add rule]                                          │ │
//! │  └─────────────────────────────────────────────────────┘ │
//! │  ▸ Advanced (raw SQL)   <— AdwExpanderRow                 │
//! └────────────────────────────────────────────────────────────┘
//! ```
//!
//! Rule rebuilds: every column / operator / value mutation rebuilds
//! the entire list from `state.rules`. Heavy-handed but predictable —
//! the strip is small (typical filter <5 rules) and the cost is
//! invisible vs. the round-trip query the user is about to fire.

use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use tablepro_core::{ColumnInfo, Combinator, FilterOp, FilterRule, FilterSet, FilterValue};

/// Closure that rebuilds the rule list. Stored in an Rc<RefCell<>> so
/// every input handler can call it through one slot, avoiding the
/// type-complexity hit clippy raises on the raw signature.
type Rebuilder = Rc<dyn Fn()>;
type RebuilderSlot = Rc<RefCell<Option<Rebuilder>>>;

fn extra_is_blank(extra: Option<&str>) -> bool {
    extra.map(|s| s.trim().is_empty()).unwrap_or(true)
}

/// Operator rendered in the Op dropdown — label, FilterOp, and
/// whether the rule needs a value.
struct OpEntry {
    op: FilterOp,
    label: &'static str,
    /// Shape of the value widget: None / Single / Pair / List.
    shape: ValueShape,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ValueShape {
    None,
    Single,
    Pair,
    List,
}

/// Allowlist of operators per type kind. The dialog narrows the Op
/// dropdown to this set when the user picks a column. Mirrors the
/// per-driver classifier in `core::filter::classify` but maps to UI
/// labels instead of SQL.
fn operators_for(data_type: &str) -> &'static [OpEntry] {
    let lower = data_type.to_ascii_lowercase();
    if lower == "tinyint(1)" || lower == "boolean" || lower == "bool" {
        return &OPS_BOOL;
    }
    if lower == "uuid" {
        return &OPS_UUID;
    }
    if lower == "jsonb" || lower == "json" {
        return &OPS_UUID; // identity-only set, same shape
    }
    if lower.contains("with time zone") || lower.contains("timestamptz") {
        return &OPS_NUMERIC;
    }
    if lower.contains("timestamp") || lower.contains("datetime") {
        return &OPS_NUMERIC;
    }
    if lower.contains("date") {
        return &OPS_NUMERIC;
    }
    if lower == "time" || lower.starts_with("time(") {
        return &OPS_NUMERIC;
    }
    if lower.contains("decimal") || lower.contains("numeric") || lower.contains("double") {
        return &OPS_NUMERIC;
    }
    if lower.contains("real") || lower.contains("float") {
        return &OPS_NUMERIC;
    }
    if lower.starts_with("int")
        || lower.starts_with("bigint")
        || lower.starts_with("smallint")
        || lower.starts_with("tinyint")
        || lower.contains("serial")
    {
        return &OPS_NUMERIC;
    }
    &OPS_TEXT
}

const OPS_TEXT: [OpEntry; 14] = [
    OpEntry {
        op: FilterOp::Eq,
        label: "equals",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::NotEq,
        label: "doesn't equal",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Contains,
        label: "contains",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::StartsWith,
        label: "starts with",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::EndsWith,
        label: "ends with",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Like,
        label: "LIKE",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::NotLike,
        label: "NOT LIKE",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Ilike,
        label: "ILIKE (case-insensitive)",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::IsNull,
        label: "is empty",
        shape: ValueShape::None,
    },
    OpEntry {
        op: FilterOp::IsNotNull,
        label: "is not empty",
        shape: ValueShape::None,
    },
    OpEntry {
        op: FilterOp::In,
        label: "is one of",
        shape: ValueShape::List,
    },
    OpEntry {
        op: FilterOp::NotIn,
        label: "is none of",
        shape: ValueShape::List,
    },
    OpEntry {
        op: FilterOp::Lt,
        label: "less than (lex)",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Gt,
        label: "greater than (lex)",
        shape: ValueShape::Single,
    },
];

const OPS_NUMERIC: [OpEntry; 11] = [
    OpEntry {
        op: FilterOp::Eq,
        label: "=",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::NotEq,
        label: "≠",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Lt,
        label: "<",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::LtEq,
        label: "≤",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Gt,
        label: ">",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::GtEq,
        label: "≥",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::Between,
        label: "between",
        shape: ValueShape::Pair,
    },
    OpEntry {
        op: FilterOp::IsNull,
        label: "is empty",
        shape: ValueShape::None,
    },
    OpEntry {
        op: FilterOp::IsNotNull,
        label: "is not empty",
        shape: ValueShape::None,
    },
    OpEntry {
        op: FilterOp::In,
        label: "is one of",
        shape: ValueShape::List,
    },
    OpEntry {
        op: FilterOp::NotIn,
        label: "is none of",
        shape: ValueShape::List,
    },
];

const OPS_BOOL: [OpEntry; 3] = [
    OpEntry {
        op: FilterOp::Eq,
        label: "=",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::IsNull,
        label: "is empty",
        shape: ValueShape::None,
    },
    OpEntry {
        op: FilterOp::IsNotNull,
        label: "is not empty",
        shape: ValueShape::None,
    },
];

const OPS_UUID: [OpEntry; 4] = [
    OpEntry {
        op: FilterOp::Eq,
        label: "=",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::NotEq,
        label: "≠",
        shape: ValueShape::Single,
    },
    OpEntry {
        op: FilterOp::IsNull,
        label: "is empty",
        shape: ValueShape::None,
    },
    OpEntry {
        op: FilterOp::IsNotNull,
        label: "is not empty",
        shape: ValueShape::None,
    },
];

/// Bytes columns are filtered out of the column dropdown entirely —
/// no point letting the user pick one when nothing they could type
/// would compare meaningfully.
fn is_filterable(col: &ColumnInfo) -> bool {
    let lower = col.data_type.to_ascii_lowercase();
    !(lower.contains("bytea") || lower.contains("blob"))
}

/// The inline filter editor. BrowseTab owns one of these per tab,
/// adds `widget` as a top bar on its `AdwToolbarView`, and toggles
/// reveal via the Filter button / Ctrl+R / Esc.
pub struct FilterStrip {
    pub widget: gtk::Revealer,
    state: Rc<RefCell<FilterSet>>,
    columns: Rc<RefCell<Vec<ColumnInfo>>>,
    rebuild: RebuilderSlot,
    raw_entry: gtk::Entry,
}

impl FilterStrip {
    pub fn is_revealed(&self) -> bool {
        self.widget.reveals_child()
    }

    pub fn set_revealed(&self, revealed: bool) {
        self.widget.set_reveal_child(revealed);
    }

    pub fn toggle(&self) {
        let opening = !self.is_revealed();
        self.set_revealed(opening);
        if opening {
            // Drop the cursor in the raw SQL field so the user can
            // start typing immediately. Raw is the primary path; the
            // rule editor is one expander click away for the click-
            // driven case.
            self.raw_entry.grab_focus();
        }
    }

    /// Refresh column metadata after a `ColumnsLoaded`. Drops any
    /// existing operator dropdowns whose column type changed and
    /// rebuilds the rule list against the new schema.
    pub fn update_columns(&self, columns: Vec<ColumnInfo>) {
        *self.columns.borrow_mut() = columns.into_iter().filter(is_filterable).collect();
        if let Some(f) = self.rebuild.borrow().as_ref() {
            f();
        }
    }

    /// Replace the strip's editing state with `set` and rebuild the
    /// rule list. Called when a filter applies from outside the
    /// strip (e.g. saved-filter restore on tab open) so the editor
    /// reflects what's actually in effect.
    pub fn update_filter(&self, set: FilterSet) {
        let extra = set.extra_sql.clone().unwrap_or_default();
        *self.state.borrow_mut() = set;
        // Raw entry mirrors state too — without this the entry's
        // text still shows the previous raw fragment after a
        // FilterApplied that cleared it.
        self.raw_entry.set_text(&extra);
        if let Some(f) = self.rebuild.borrow().as_ref() {
            f();
        }
    }
}

pub fn build(columns: Vec<ColumnInfo>, initial: FilterSet, on_apply: Rc<dyn Fn(FilterSet)>) -> FilterStrip {
    let state = Rc::new(RefCell::new(initial));
    let columns: Rc<RefCell<Vec<ColumnInfo>>> =
        Rc::new(RefCell::new(columns.into_iter().filter(is_filterable).collect()));

    // Outer revealer — slides the strip into / out of view. Slide-down
    // matches GtkSearchBar's reveal direction, so the strip reads as
    // a transient editor descending from the toolbar.
    let revealer = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::SlideDown)
        .reveal_child(false)
        .build();

    let outer = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();
    outer.add_css_class("toolbar");
    outer.add_css_class("inline-toolbar");
    revealer.set_child(Some(&outer));

    // Top bar: title on the left, action buttons on the right. Inline
    // (not an AdwHeaderBar) because the strip doesn't own a window
    // chrome — it's a piece of toolbar inside the BrowseTab's
    // ToolbarView.
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_top(8)
        .margin_bottom(0)
        .margin_start(12)
        .margin_end(12)
        .build();
    // Header reads as a single concise row: small "Match … of these
    // rules:" label on the left with the combinator dropdown inline
    // (only revealed once 2+ rules exist, since AND/OR is meaningless
    // with 0–1 rules), spacer, action buttons on the right. Drops the
    // earlier "Filter rows" title — Apply / Clear / × already mark
    // this as the filter editor.
    let match_label = gtk::Label::builder().label(crate::tr!("Match")).build();
    match_label.add_css_class("dim-label");
    let combinator_dropdown = gtk::DropDown::from_strings(&[&crate::tr!("all"), &crate::tr!("any")]);
    combinator_dropdown.set_valign(gtk::Align::Center);
    combinator_dropdown.set_selected(match state.borrow().combinator {
        Combinator::And => 0,
        Combinator::Or => 1,
    });
    let match_suffix = gtk::Label::builder().label(crate::tr!("of these rules")).build();
    match_suffix.add_css_class("dim-label");
    let match_row_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .build();
    match_row_box.append(&match_label);
    match_row_box.append(&combinator_dropdown);
    match_row_box.append(&match_suffix);
    let match_revealer = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::None)
        .reveal_child(state.borrow().rules.len() >= 2)
        .child(&match_row_box)
        .build();
    let spacer = gtk::Box::builder().hexpand(true).build();
    let clear_btn = gtk::Button::with_label(&crate::tr!("Clear all"));
    clear_btn.add_css_class("flat");
    let apply_btn = gtk::Button::with_label(&crate::tr!("Apply"));
    apply_btn.add_css_class("suggested-action");
    let close_btn = gtk::Button::builder()
        .icon_name("window-close-symbolic")
        .tooltip_text(crate::tr!("Close (Esc)"))
        .build();
    close_btn.add_css_class("flat");
    header.append(&match_revealer);
    header.append(&spacer);
    header.append(&clear_btn);
    header.append(&apply_btn);
    header.append(&close_btn);
    outer.append(&header);

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(6)
        .margin_bottom(8)
        .margin_start(12)
        .margin_end(12)
        .build();

    let state_for_combinator = state.clone();
    combinator_dropdown.connect_selected_notify(move |dd| {
        state_for_combinator.borrow_mut().combinator = match dd.selected() {
            1 => Combinator::Or,
            _ => Combinator::And,
        };
    });

    // Rebuild closure — captured by every input-changed callback.
    // Drains the rules list, walks `state.rules`, builds a row per
    // rule. Re-entrancy guard: a CHANGED signal fired while we're
    // rebuilding (programmatic set_text on an EntryRow) would
    // re-enter and double-update state. The suppress flag
    // short-circuits during rebuild.
    let suppress: Rc<std::cell::Cell<bool>> = Rc::new(std::cell::Cell::new(false));
    let rebuild: RebuilderSlot = Rc::new(RefCell::new(None));

    // Raw SQL input — primary, always-visible. The strip is aimed
    // at developers who already think in WHERE clauses; making them
    // expand a section to type SQL would be backwards. Structured
    // rules become the secondary affordance below.
    let raw_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    let where_label = gtk::Label::builder().label("WHERE").build();
    where_label.add_css_class("monospace");
    where_label.add_css_class("dim-label");
    let raw_entry = gtk::Entry::builder()
        .placeholder_text(crate::tr!("e.g. created_at > now() - interval '1 day'"))
        .hexpand(true)
        .build();
    raw_entry.add_css_class("monospace");
    raw_entry.set_text(state.borrow().extra_sql.as_deref().unwrap_or(""));
    let state_for_raw = state.clone();
    let rebuild_for_raw = rebuild.clone();
    raw_entry.connect_changed(move |e| {
        let text = e.text().to_string();
        let trimmed = text.trim();
        state_for_raw.borrow_mut().extra_sql = if trimmed.is_empty() { None } else { Some(text) };
        // Re-evaluate the Match revealer — combinator visibility
        // depends on whether raw + ≥1 rule are both present.
        if let Some(f) = rebuild_for_raw.borrow().as_ref() {
            f();
        }
    });
    let apply_btn_for_enter = apply_btn.clone();
    raw_entry.connect_activate(move |_| {
        apply_btn_for_enter.activate();
    });
    raw_row.append(&where_label);
    raw_row.append(&raw_entry);
    content.append(&raw_row);

    // Structured rules — secondary, collapsed by default. Power
    // users who think in raw SQL never need to expand this; users
    // building filters by clicking get a dropdown-driven editor
    // when they reach for it. Pre-expanded only when the saved
    // FilterSet already has rules from a previous session.
    let rules_expander = gtk::Expander::builder()
        .label(crate::tr!("Or use the rule editor"))
        .expanded(!state.borrow().rules.is_empty())
        .build();
    let rules_body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(8)
        .build();
    rules_expander.set_child(Some(&rules_body));
    content.append(&rules_expander);

    let rules_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    rules_list.add_css_class("boxed-list");
    rules_body.append(&rules_list);

    // Inline "Add rule" button — small, left-aligned, flat.
    let add_rule_btn = gtk::Button::builder()
        .icon_name("list-add-symbolic")
        .label(crate::tr!("Add rule"))
        .halign(gtk::Align::Start)
        .build();
    add_rule_btn.add_css_class("flat");
    rules_body.append(&add_rule_btn);

    {
        let rules_list = rules_list.clone();
        let state = state.clone();
        let columns = columns.clone();
        let suppress = suppress.clone();
        let rebuild_inner = rebuild.clone();
        let match_revealer = match_revealer.clone();
        let closure: Rebuilder = Rc::new(move || {
            suppress.set(true);
            while let Some(child) = rules_list.first_child() {
                rules_list.remove(&child);
            }
            let rules_snapshot = state.borrow().rules.clone();
            for (i, rule) in rules_snapshot.iter().enumerate() {
                let row = build_rule_row(
                    i,
                    rule,
                    &columns,
                    state.clone(),
                    rebuild_inner.clone(),
                    suppress.clone(),
                );
                rules_list.append(&row);
            }
            // Match dropdown is meaningful when at least two clauses
            // need a combinator — that's ≥2 structured rules, or 1
            // structured rule combined with raw SQL. Hide it
            // otherwise so the user doesn't see a control that has
            // no effect on the resulting WHERE.
            let raw_present = !extra_is_blank(state.borrow().extra_sql.as_deref());
            let needs_combinator = rules_snapshot.len() >= 2 || (!rules_snapshot.is_empty() && raw_present);
            match_revealer.set_reveal_child(needs_combinator);
            // Visually mute the entire rules list when empty so the
            // strip reads as ready-for-input rather than already-
            // populated.
            rules_list.set_visible(!rules_snapshot.is_empty());
            suppress.set(false);
        });
        *rebuild.borrow_mut() = Some(closure);
    }
    if let Some(f) = rebuild.borrow().as_ref() {
        f();
    }

    let state_for_add = state.clone();
    let columns_for_add = columns.clone();
    let rebuild_for_add = rebuild.clone();
    add_rule_btn.connect_clicked(move |_| {
        let default_col = columns_for_add
            .borrow()
            .first()
            .map(|c| c.name.clone())
            .unwrap_or_default();
        state_for_add.borrow_mut().rules.push(FilterRule {
            column: default_col,
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(String::new())),
        });
        if let Some(f) = rebuild_for_add.borrow().as_ref() {
            f();
        }
    });

    let scroller = gtk::ScrolledWindow::builder()
        .child(&content)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(false)
        .max_content_height(420)
        .propagate_natural_height(true)
        .hexpand(true)
        .build();
    outer.append(&scroller);

    let revealer_for_close = revealer.clone();
    close_btn.connect_clicked(move |_| {
        revealer_for_close.set_reveal_child(false);
    });

    let revealer_for_clear = revealer.clone();
    let on_apply_for_clear = on_apply.clone();
    clear_btn.connect_clicked(move |_| {
        on_apply_for_clear(FilterSet::default());
        revealer_for_clear.set_reveal_child(false);
    });

    let revealer_for_apply = revealer.clone();
    let state_for_apply = state.clone();
    apply_btn.connect_clicked(move |_| {
        let snapshot = state_for_apply.borrow().clone();
        on_apply(snapshot);
        revealer_for_apply.set_reveal_child(false);
    });

    // Esc inside the strip collapses it without applying. Local
    // scope so it doesn't compete with cell-editor / search-bar Esc
    // handlers elsewhere in the BrowseTab.
    let revealer_for_esc = revealer.clone();
    let esc_shortcut = gtk::Shortcut::builder()
        .trigger(&gtk::ShortcutTrigger::parse_string("Escape").expect("valid trigger"))
        .action(&gtk::CallbackAction::new(move |_, _| {
            revealer_for_esc.set_reveal_child(false);
            relm4::gtk::glib::Propagation::Stop
        }))
        .build();
    let esc_controller = gtk::ShortcutController::new();
    esc_controller.set_scope(gtk::ShortcutScope::Local);
    esc_controller.add_shortcut(esc_shortcut);
    outer.add_controller(esc_controller);

    FilterStrip {
        widget: revealer,
        state,
        columns,
        rebuild,
        raw_entry,
    }
}

fn build_rule_row(
    index: usize,
    rule: &FilterRule,
    columns: &Rc<RefCell<Vec<ColumnInfo>>>,
    state: Rc<RefCell<FilterSet>>,
    rebuild: RebuilderSlot,
    suppress: Rc<std::cell::Cell<bool>>,
) -> adw::ActionRow {
    let columns_snapshot = columns.borrow().clone();
    let row = adw::ActionRow::builder().build();

    // Column dropdown (prefix).
    let names: Vec<&str> = columns_snapshot.iter().map(|c| c.name.as_str()).collect();
    let column_dd = gtk::DropDown::from_strings(&names);
    column_dd.set_valign(gtk::Align::Center);
    let initial_col_idx = columns_snapshot.iter().position(|c| c.name == rule.column).unwrap_or(0) as u32;
    column_dd.set_selected(initial_col_idx);

    let state_for_col = state.clone();
    let columns_for_col = columns.clone();
    let rebuild_for_col = rebuild.clone();
    let suppress_for_col = suppress.clone();
    column_dd.connect_selected_notify(move |dd| {
        if suppress_for_col.get() {
            return;
        }
        let idx = dd.selected() as usize;
        let cols = columns_for_col.borrow();
        let Some(new_col) = cols.get(idx) else {
            return;
        };
        if let Some(rule) = state_for_col.borrow_mut().rules.get_mut(index) {
            rule.column = new_col.name.clone();
            // Reset the operator to the first valid one for the new
            // column type — text-only ops on a new int column would
            // produce SQL the driver rejects at fetch time.
            let ops = operators_for(&new_col.data_type);
            rule.op = ops[0].op;
            rule.value = match ops[0].shape {
                ValueShape::None => None,
                ValueShape::Single => Some(FilterValue::Single(String::new())),
                ValueShape::Pair => Some(FilterValue::Pair(String::new(), String::new())),
                ValueShape::List => Some(FilterValue::List(Vec::new())),
            };
        }
        drop(cols);
        if let Some(f) = rebuild_for_col.borrow().as_ref() {
            f();
        }
    });
    row.add_prefix(&column_dd);

    // Operator dropdown.
    let col = columns_snapshot
        .get(initial_col_idx as usize)
        .cloned()
        .unwrap_or_else(|| ColumnInfo {
            name: rule.column.clone(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        });
    let ops = operators_for(&col.data_type);
    let op_labels: Vec<&str> = ops.iter().map(|e| e.label).collect();
    let op_dd = gtk::DropDown::from_strings(&op_labels);
    op_dd.set_valign(gtk::Align::Center);
    let op_idx = ops.iter().position(|e| e.op == rule.op).unwrap_or(0) as u32;
    op_dd.set_selected(op_idx);

    let state_for_op = state.clone();
    let columns_for_op = columns.clone();
    let rebuild_for_op = rebuild.clone();
    let suppress_for_op = suppress.clone();
    op_dd.connect_selected_notify(move |dd| {
        if suppress_for_op.get() {
            return;
        }
        let new_idx = dd.selected() as usize;
        let mut state_mut = state_for_op.borrow_mut();
        let Some(rule) = state_mut.rules.get_mut(index) else {
            return;
        };
        let col = columns_for_op
            .borrow()
            .iter()
            .find(|c| c.name == rule.column)
            .cloned()
            .unwrap_or_else(|| ColumnInfo {
                name: rule.column.clone(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
            });
        let ops = operators_for(&col.data_type);
        if let Some(entry) = ops.get(new_idx) {
            rule.op = entry.op;
            rule.value = match entry.shape {
                ValueShape::None => None,
                ValueShape::Single => Some(FilterValue::Single(String::new())),
                ValueShape::Pair => Some(FilterValue::Pair(String::new(), String::new())),
                ValueShape::List => Some(FilterValue::List(Vec::new())),
            };
        }
        drop(state_mut);
        if let Some(f) = rebuild_for_op.borrow().as_ref() {
            f();
        }
    });
    row.add_suffix(&op_dd);

    // Value widget(s) — shape depends on operator.
    let shape = ops
        .iter()
        .find(|e| e.op == rule.op)
        .map(|e| e.shape)
        .unwrap_or(ValueShape::Single);
    match shape {
        ValueShape::None => {
            // No input widget; the title carries enough meaning.
        }
        ValueShape::Single => {
            let entry = gtk::Entry::builder()
                .placeholder_text(crate::tr!("Value"))
                .valign(gtk::Align::Center)
                .hexpand(true)
                .build();
            entry.set_input_purpose(input_purpose_for(&col.data_type));
            if let Some(FilterValue::Single(s)) = rule.value.as_ref() {
                entry.set_text(s);
            }
            let state_for_value = state.clone();
            let suppress_for_value = suppress.clone();
            entry.connect_changed(move |e| {
                if suppress_for_value.get() {
                    return;
                }
                if let Some(rule) = state_for_value.borrow_mut().rules.get_mut(index) {
                    rule.value = Some(FilterValue::Single(e.text().to_string()));
                }
            });
            row.add_suffix(&entry);
        }
        ValueShape::Pair => {
            let lo = gtk::Entry::builder()
                .placeholder_text(crate::tr!("From"))
                .valign(gtk::Align::Center)
                .build();
            let hi = gtk::Entry::builder()
                .placeholder_text(crate::tr!("To"))
                .valign(gtk::Align::Center)
                .build();
            lo.set_input_purpose(input_purpose_for(&col.data_type));
            hi.set_input_purpose(input_purpose_for(&col.data_type));
            if let Some(FilterValue::Pair(a, b)) = rule.value.as_ref() {
                lo.set_text(a);
                hi.set_text(b);
            }
            let state_for_lo = state.clone();
            let suppress_for_lo = suppress.clone();
            let hi_for_lo = hi.clone();
            lo.connect_changed(move |e| {
                if suppress_for_lo.get() {
                    return;
                }
                if let Some(rule) = state_for_lo.borrow_mut().rules.get_mut(index) {
                    rule.value = Some(FilterValue::Pair(e.text().to_string(), hi_for_lo.text().to_string()));
                }
            });
            let state_for_hi = state.clone();
            let suppress_for_hi = suppress.clone();
            let lo_for_hi = lo.clone();
            hi.connect_changed(move |e| {
                if suppress_for_hi.get() {
                    return;
                }
                if let Some(rule) = state_for_hi.borrow_mut().rules.get_mut(index) {
                    rule.value = Some(FilterValue::Pair(lo_for_hi.text().to_string(), e.text().to_string()));
                }
            });
            let pair_box = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(6)
                .build();
            pair_box.append(&lo);
            pair_box.append(&hi);
            row.add_suffix(&pair_box);
        }
        ValueShape::List => {
            let entry = gtk::Entry::builder()
                .placeholder_text(crate::tr!("a, b, c"))
                .valign(gtk::Align::Center)
                .hexpand(true)
                .build();
            if let Some(FilterValue::List(items)) = rule.value.as_ref() {
                entry.set_text(&items.join(", "));
            }
            let state_for_value = state.clone();
            let suppress_for_value = suppress.clone();
            entry.connect_changed(move |e| {
                if suppress_for_value.get() {
                    return;
                }
                if let Some(rule) = state_for_value.borrow_mut().rules.get_mut(index) {
                    let items: Vec<String> = e
                        .text()
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                    rule.value = Some(FilterValue::List(items));
                }
            });
            row.add_suffix(&entry);
        }
    }

    // Trash button — removes this rule.
    let remove = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove rule"))
        .valign(gtk::Align::Center)
        .build();
    remove.add_css_class("flat");
    let state_for_remove = state.clone();
    let rebuild_for_remove = rebuild.clone();
    remove.connect_clicked(move |_| {
        let mut s = state_for_remove.borrow_mut();
        if index < s.rules.len() {
            s.rules.remove(index);
        }
        drop(s);
        if let Some(f) = rebuild_for_remove.borrow().as_ref() {
            f();
        }
    });
    row.add_suffix(&remove);

    row
}

fn input_purpose_for(data_type: &str) -> gtk::InputPurpose {
    let lower = data_type.to_ascii_lowercase();
    let is_numeric = lower.starts_with("int")
        || lower.starts_with("bigint")
        || lower.starts_with("smallint")
        || lower.starts_with("tinyint")
        || lower.contains("serial")
        || lower.contains("decimal")
        || lower.contains("numeric")
        || lower.contains("double")
        || lower.contains("real")
        || lower.contains("float");
    if is_numeric {
        gtk::InputPurpose::Number
    } else {
        gtk::InputPurpose::FreeForm
    }
}
