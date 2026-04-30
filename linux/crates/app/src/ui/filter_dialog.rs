//! Filter rules editor — server-side WHERE clause for the active
//! Browse tab. Reachable via the "Filter" button on the paginator
//! action bar or the Ctrl+R shortcut.
//!
//! Built as a plain `present()` function (no Relm4 component) because
//! the dialog is fire-and-forget: caller hands in initial state +
//! `on_apply` / `on_clear` callbacks, the dialog mutates a shared Rc
//! while the user edits, and on Apply or Clear it invokes the
//! callback and closes itself.
//!
//! UI shape (single-level combinator, no nested groups):
//!
//! ```text
//! ┌─ Filter rows ──────────────────── Cancel │ Clear all │ Apply ─┐
//! │  Combine rules with: [ All  ▾ ]   <— AND or OR DropDown       │
//! │  ┌─ boxed-list ListBox ─────────────────────────────────────┐ │
//! │  │ [Column ▾] [Op ▾] [Value …]                  [✕]          │ │
//! │  │ [Column ▾] [Op ▾] [Value …]                  [✕]          │ │
//! │  │ [+ Add rule]                                              │ │
//! │  └─────────────────────────────────────────────────────────┘ │
//! └────────────────────────────────────────────────────────────────┘
//! ```
//!
//! Rule rebuilds: every column / operator / value mutation rebuilds
//! the entire list from `state.rules`. Heavy-handed but predictable —
//! the dialog is small (typical filter <5 rules) and the cost is
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

pub fn present(
    parent: &impl IsA<gtk::Widget>,
    columns: Vec<ColumnInfo>,
    initial: FilterSet,
    on_apply: Rc<dyn Fn(FilterSet)>,
) {
    let state = Rc::new(RefCell::new(initial));
    let columns: Rc<Vec<ColumnInfo>> = Rc::new(columns.into_iter().filter(is_filterable).collect());

    let dialog = adw::Dialog::builder()
        .title(crate::tr!("Filter rows"))
        .content_width(580)
        .content_height(640)
        .build();

    let header = adw::HeaderBar::builder()
        .show_start_title_buttons(false)
        .show_end_title_buttons(false)
        .build();
    let cancel_btn = gtk::Button::with_label(&crate::tr!("Cancel"));
    let clear_btn = gtk::Button::with_label(&crate::tr!("Clear all"));
    clear_btn.add_css_class("flat");
    let apply_btn = gtk::Button::with_label(&crate::tr!("Apply"));
    apply_btn.add_css_class("suggested-action");
    header.pack_start(&cancel_btn);
    header.pack_end(&apply_btn);
    header.pack_end(&clear_btn);

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(18)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();

    // Match-combinator row. AdwActionRow in a tiny boxed-list with
    // a trailing DropDown — visually parallel to the rules list
    // below it, so the user reads "Combine with: All / Any" as a
    // sibling of "Rules".
    let match_group = adw::PreferencesGroup::builder().title(crate::tr!("Match")).build();
    let match_row = adw::ActionRow::builder()
        .title(crate::tr!("Combine rules with"))
        .build();
    let combinator_dropdown = gtk::DropDown::from_strings(&[&crate::tr!("All (AND)"), &crate::tr!("Any (OR)")]);
    combinator_dropdown.set_valign(gtk::Align::Center);
    combinator_dropdown.set_selected(match state.borrow().combinator {
        Combinator::And => 0,
        Combinator::Or => 1,
    });
    match_row.add_suffix(&combinator_dropdown);
    match_group.add(&match_row);
    content.append(&match_group);

    let state_for_combinator = state.clone();
    combinator_dropdown.connect_selected_notify(move |dd| {
        state_for_combinator.borrow_mut().combinator = match dd.selected() {
            1 => Combinator::Or,
            _ => Combinator::And,
        };
    });

    // Rules section header + boxed-list. The list is rebuilt on every
    // mutation; building inside an outer Box rather than directly
    // appending to a PreferencesGroup avoids fighting AdwPreferencesGroup's
    // child-management API.
    let rules_header = gtk::Label::builder().label(crate::tr!("Rules")).xalign(0.0).build();
    rules_header.add_css_class("heading");
    content.append(&rules_header);

    let rules_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    rules_list.add_css_class("boxed-list");
    content.append(&rules_list);

    // Rebuild closure — captured by every input-changed callback.
    // Drains the list, walks `state.rules`, builds a row per rule,
    // appends "Add rule" at the end. Re-entrancy guard: a CHANGED
    // signal fired while we're rebuilding (programmatic set_text on
    // an EntryRow) would re-enter and double-update state. The
    // suppress flag short-circuits during rebuild.
    let suppress: Rc<std::cell::Cell<bool>> = Rc::new(std::cell::Cell::new(false));
    let rebuild: RebuilderSlot = Rc::new(RefCell::new(None));

    {
        let rules_list = rules_list.clone();
        let state = state.clone();
        let columns = columns.clone();
        let suppress = suppress.clone();
        let rebuild_inner = rebuild.clone();
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
            // Trailing "Add rule" row matching the structure-tab
            // boxed-list pattern.
            let add_row = adw::ButtonRow::builder()
                .title(crate::tr!("Add rule"))
                .start_icon_name("list-add-symbolic")
                .build();
            let state_for_add = state.clone();
            let columns_for_add = columns.clone();
            let rebuild_for_add = rebuild_inner.clone();
            add_row.connect_activated(move |_| {
                let default_col = columns_for_add.first().map(|c| c.name.clone()).unwrap_or_default();
                state_for_add.borrow_mut().rules.push(FilterRule {
                    column: default_col,
                    op: FilterOp::Eq,
                    value: Some(FilterValue::Single(String::new())),
                });
                if let Some(f) = rebuild_for_add.borrow().as_ref() {
                    f();
                }
            });
            rules_list.append(&add_row);
            suppress.set(false);
        });
        *rebuild.borrow_mut() = Some(closure);
    }

    if let Some(f) = rebuild.borrow().as_ref() {
        f();
    }

    let scroller = gtk::ScrolledWindow::builder()
        .child(&content)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .hexpand(true)
        .build();

    let toolbar_view = adw::ToolbarView::new();
    toolbar_view.add_top_bar(&header);
    toolbar_view.set_content(Some(&scroller));
    dialog.set_child(Some(&toolbar_view));
    dialog.set_default_widget(Some(&apply_btn));

    let dialog_for_cancel = dialog.clone();
    cancel_btn.connect_clicked(move |_| {
        dialog_for_cancel.close();
    });

    let dialog_for_clear = dialog.clone();
    let on_apply_for_clear = on_apply.clone();
    clear_btn.connect_clicked(move |_| {
        on_apply_for_clear(FilterSet::default());
        dialog_for_clear.close();
    });

    let dialog_for_apply = dialog.clone();
    let state_for_apply = state.clone();
    apply_btn.connect_clicked(move |_| {
        let snapshot = state_for_apply.borrow().clone();
        on_apply(snapshot);
        dialog_for_apply.close();
    });

    dialog.present(Some(parent));
}

fn build_rule_row(
    index: usize,
    rule: &FilterRule,
    columns: &Rc<Vec<ColumnInfo>>,
    state: Rc<RefCell<FilterSet>>,
    rebuild: RebuilderSlot,
    suppress: Rc<std::cell::Cell<bool>>,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder().build();

    // Column dropdown (prefix).
    let names: Vec<&str> = columns.iter().map(|c| c.name.as_str()).collect();
    let column_dd = gtk::DropDown::from_strings(&names);
    column_dd.set_valign(gtk::Align::Center);
    let initial_col_idx = columns.iter().position(|c| c.name == rule.column).unwrap_or(0) as u32;
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
        let Some(new_col) = columns_for_col.get(idx) else {
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
        if let Some(f) = rebuild_for_col.borrow().as_ref() {
            f();
        }
    });
    row.add_prefix(&column_dd);

    // Operator dropdown.
    let col = columns
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
