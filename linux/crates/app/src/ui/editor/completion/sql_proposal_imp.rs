use std::cell::{Cell, OnceCell};

use gtk4::glib;
use gtk4::subclass::prelude::*;
use sourceview5::subclass::prelude::*;

use super::proposal_kind::ProposalKind;

#[derive(Default)]
pub struct SqlProposal {
    pub kind: OnceCell<ProposalKind>,
    pub label: OnceCell<String>,
    pub insert_text: OnceCell<String>,
    /// The last fuzzy score, written by the filter for the sorter.
    pub priority: Cell<u32>,
}

#[glib::object_subclass]
impl ObjectSubclass for SqlProposal {
    const NAME: &'static str = "TableProSqlProposal";
    type Type = super::sql_proposal::SqlProposal;
    type Interfaces = (sourceview5::CompletionProposal,);
}

impl ObjectImpl for SqlProposal {}

impl CompletionProposalImpl for SqlProposal {}
